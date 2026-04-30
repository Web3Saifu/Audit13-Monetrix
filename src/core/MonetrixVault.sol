// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.27;

import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/math/SafeCast.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "../tokens/USDM.sol";
import "../tokens/sUSDM.sol";
import "./MonetrixConfig.sol";
import "./InsuranceFund.sol";
import "../interfaces/IHyperCore.sol";
import "../interfaces/HyperCoreConstants.sol";
import "../interfaces/IMonetrixAccountant.sol";
import "../interfaces/IRedeemEscrow.sol";
import "../interfaces/IYieldEscrow.sol";
import "./ActionEncoder.sol";
import "./PrecompileReader.sol";
import "./TokenMath.sol";
import "./MonetrixAccountant.sol";
import {MonetrixGovernedUpgradeable} from "../governance/MonetrixGovernedUpgradeable.sol";

/// @title MonetrixVault - Core vault managing USDC deposits, USDM minting, redemption queue, and L1 hedge execution
/// @dev Role mapping (via shared MonetrixAccessController):
///      - GUARDIAN: pause / unpause / pauseOperator / unpauseOperator (delay=0)
///      - OPERATOR: bridge / hedge / HLP / yield-distribution (delay=0)
///      - GOVERNOR: set* / emergency* (24h timelock)
///      - UPGRADER: _authorizeUpgrade (48h timelock, inherited from base)
/// @dev Two-dimensional pause:
///      - `paused` (OZ Pausable): user fund I/O — deposit, redeem claim, outflow paths.
///      - `operatorPaused` (custom):    all operator-driven mutations (hedge/HLP/BLP/bridges/yield).
///      Outflow functions (`keeperBridge`, `settle`, `distributeYield`) are gated by BOTH.
contract MonetrixVault is PausableUpgradeable, ReentrancyGuard, MonetrixGovernedUpgradeable {
    using SafeERC20 for IERC20;

    enum BridgeTarget { Vault, Multisig }//👉 This decides where bridged money should go on L1 side:,,,bridge USDC → either stays in system or goes to admin backup wallet

    // ═══════════════════════════════════════════════════════════
    //                      STATE
    // ═══════════════════════════════════════════════════════════

    // ─── Core references ────────────────────────────────────
    IERC20 public usdc;
    USDM public usdm;//👉 This is the protocol’s “receipt token” minted 1:1 when user deposits USDC.
    sUSDM public susdm;//👉 This is the staking version of USDM that earns yield.//stake USDM → earn profit over time
    MonetrixConfig public config;//👉 This stores all protocol rules like:
    address public coreDepositWallet;//👉 This is the bridge gateway that sends funds to L1 trading system.//“door to external trading system”
    address public accountant;//👉 This is the “brain” that calculates://decides how much profit protocol made today
    address public multisigVault;//👉 Backup admin-controlled wallet used for emergency or alternative fund routing.//if system fails → money can go here
    address public redeemEscrow;//👉 Holds user withdrawal requests (locked pending USDC).//user requests withdraw → stored here until paid
    address public yieldEscrow;//👉 Temporary storage for generated profit before distribution.//👉 Temporary storage for generated profit before distribution.

    // ─── Operational state ──────────────────────────────────
    bool public hlpDepositEnabled;// 👉 HLP = Hyperliquid Liquidity Pool// 🏦 A pool where you deposit funds → traders use it → you earn fees//👉 Controls whether users/system can deposit into HLP strategy.//true → system sends money to trading pool,,false → HLP strategy paused//“turn ON/OFF earning strategy”
    bool public multisigVaultEnabled;//👉 Allows routing funds to multisig wallet,,“backup money routing switch”
    uint256 public lastBridgeTimestamp;//👉 Last time funds were sent to L1.

    // ─── L1 principal tracking ───────────────────────────────
    uint256 public outstandingL1Principal;//👉 Total money currently sent to L1 (active in trading).
    uint256 public bridgeRetentionAmount;//👉 Minimum amount kept in vault (don’t send everything to L1).

    // ─── Redeem queue ───────────────────────────────────────
    /// @dev 2-slot layout without exotic bit widths. `owner` (160 bits) +
    ///      `cooldownEnd` (64 bits) packs into slot 0 (224/256 used); amount
    ///      takes the full uint256 slot 1 — same storage cost as the former
    ///      uint152/uint104 packing, but no truncation risk on usdmAmount.
    struct RedeemRequest {
        address owner;        // slot 0 ┐//owner → who requested
        uint64  cooldownEnd;  // slot 0 ┘///cooldownEnd → when they can claim
        uint256 usdmAmount;   // slot 1//usdmAmount → how much to withdraw
    }

    uint256 public nextRedeemId;//👉 Counter to give unique ID for each withdraw request.
    mapping(uint256 => RedeemRequest) public redeemRequests;//👉 Stores all withdraw requests by ID.
    mapping(address => uint256[]) private _userRedeemIds;//👉 Tracks which requests belong to each user.

    /// @notice PM activation flag for Vault's L1 account; when true, `_sendL1Bridge` counts 0x811 supplied.
    bool public pmEnabled;//Instead of keeping funds separate, the system treats all assets as one combined portfolio           //note

    /// @notice Operator-side pause (independent of `paused`). When true, blocks every operator-driven
    ///         mutation (hedge/HLP/BLP/bridges/yield/escrow routing). User-facing functions keep
    ///         their own `whenNotPaused` gate and are unaffected.
    bool public operatorPaused;//👉 Stops all operator actions (hedge, bridge, yield).

    uint256[50] private __gap;

    // ─── Events ─────────────────────────────────────────────
    event Deposited(address indexed user, uint256 amount);
    event RedeemRequested(uint256 indexed requestId, address indexed owner, uint256 usdmAmount, uint256 cooldownEnd);//👉 Logs when user requests withdrawal (starts cooldown)
    event RedeemClaimed(uint256 indexed requestId, address indexed owner, uint256 usdmAmount);//👉 Logs when user actually receives money after cooldown
    event BridgedToL1(uint256 amount);//👉 Logs when vault sends funds to L1 for trading
    event PrincipalBridgedFromL1(uint256 amount);
    event YieldBridgedFromL1(uint256 amount);
    event YieldCollected(uint256 amount);
    event YieldDistributed(uint256 totalYield, uint256 userShare, uint256 insuranceShare, uint256 foundationShare);
    event HedgeExecuted(uint256 indexed batchId, uint32 spotAsset, uint32 perpAsset, uint64 size);
    event HedgeClosed(uint256 indexed positionId, uint32 spotAsset, uint64 size);
    event HedgeRepaired(uint256 indexed positionId, uint16 residualBps);
    event HlpDeposited(uint64 usdAmount);
    event HlpWithdrawn(uint64 usdAmount);
    event HlpDepositEnabledUpdated(bool enabled);
    event RedemptionsFunded(uint256 amount);
    event RedeemEscrowReclaimed(uint256 amount);//“Unused withdrawal funds are returned from escrow to the vault.”
    event EmergencyActionSent(address indexed sender, bytes32 dataHash);
    event AccountantUpdated(address newAccountant);//“Logs when the system replaces the PnL calculation contract.”
    event MultisigVaultUpdated(address newMultisigVault);
    event RedeemEscrowUpdated(address redeemEscrow);
    event YieldEscrowUpdated(address yieldEscrow);
    event BridgeRetentionAmountUpdated(uint256 amount);//💼 900,000 → invested (loans, bonds, etc.),,🏦 100,000 → kept in vault (retention)
    event PmEnabledUpdated(bool enabled);//👉 Logs when portfolio margin mode toggled
    event BlpSupplied(uint64 indexed token, uint64 l1Amount);//👉 Logs when vault supplies tokens to lending pool
    event BlpWithdrawn(uint64 indexed token, uint64 l1Amount);//👉 Logs when vault withdraws from lending pool
    event OperatorPaused(address indexed by);
    event OperatorUnpaused(address indexed by);
 


    // ═══════════════════════════════════════════════════════════
    //                    INITIALIZER
    // ═══════════════════════════════════════════════════════════

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address _usdc,
        address _usdm,//👉 Address of USDM (minted stablecoin)
        address _susdm,//👉 Address of yield token (earning version)
        address _config,//👉 Address of config contract (rules/settings)
        address _coreDepositWallet,//👉 Address used to send funds to L1 trading system
        address _acl//👉 Access control contract (roles: operator, governor, etc.)
    ) external initializer {
        require(_usdc != address(0) && _usdm != address(0) && _susdm != address(0), "zero token");
        require(_config != address(0) && _coreDepositWallet != address(0), "zero dep");

        __Pausable_init();
        __Governed_init(_acl);

        usdc = IERC20(_usdc);
        usdm = USDM(_usdm);
        susdm = sUSDM(_susdm);
        config = MonetrixConfig(_config);
        coreDepositWallet = _coreDepositWallet;
        hlpDepositEnabled = true;
    }

    
    // ═══════════════════════════════════════════════════════════
    //                      MODIFIER
    // ═══════════════════════════════════════════════════════════

    modifier requireWired() {
        require(accountant != address(0) && redeemEscrow != address(0) && yieldEscrow != address(0), "not wired");
        _;
    }

    modifier whenOperatorNotPaused() {
        require(!operatorPaused, "operator paused");
        _;
    }

    // ═══════════════════════════════════════════════════════════
    //                   USER OPERATIONS
    // ═══════════════════════════════════════════════════════════
//@audit-ok 
    function deposit(uint256 amount) external nonReentrant whenNotPaused {//User gives USDC → gets USDM
        require(
            amount >= config.minDepositAmount() && amount <= config.maxDepositAmount(),// @audit access control cheack?
            "deposit out of range"
        );
        uint256 maxTVL = config.maxTVL();//👉 Get maximum total money allowed in protocol
        if (maxTVL > 0) {
            require(usdm.totalSupply() + amount <= maxTVL, "TVL cap exceeded");//👉 Ensures total deposits don’t exceed system limit
        }
        usdc.safeTransferFrom(msg.sender, address(this), amount);
        usdm.mint(msg.sender, amount);
        emit Deposited(msg.sender, amount);
    }
  //@audit F6. Stale request state risk,,👉 request exists but system state changed (config/escrow mismatch)
  // @audit Partial execution possible?
   // @audit USDM is always redeemable 1:1
    // @audit Can I create imbalance (owed vs liquidity)?
    //@audit-ok 
       function requestRedeem(uint256 usdmAmount) external nonReentrant whenNotPaused requireWired returns (uint256 requestId) {//User says: “I want my money back” (but not instantly)//👉 User requests to withdraw using USDM
        require(usdmAmount > 0, "zero amount");
        IERC20(address(usdm)).safeTransferFrom(msg.sender, address(this), usdmAmount);//👉 User sends USDM → vault,,User is giving back their claim token
        IRedeemEscrow(redeemEscrow).addObligation(usdmAmount);//“Protocol now owes this amount to users

        requestId = nextRedeemId++;//👉 Unique ID for this withdrawal
        redeemRequests[requestId] = RedeemRequest({
            owner: msg.sender,///who → user
            cooldownEnd: SafeCast.toUint64(block.timestamp + config.redeemCooldown())// 👉 “Set the time when user can withdraw”//config.redeemCooldown()👉 Waiting time (redeemCooldown = 3 days;)//SafeCast.toUint64(...)👉 Convert the value to uint64 safely(avoid overflow / fit into smaller storage)
        });
        _userRedeemIds[msg.sender].push(requestId);//👉 Link this request to user
        emit RedeemRequested(requestId, msg.sender, usdmAmount, block.timestamp + config.redeemCooldown());
    }
//@audit-ok 
    function claimRedeem(uint256 requestId) external nonReentrant whenNotPaused requireWired {//User finally gets USDC after waiting
        RedeemRequest memory req = redeemRequests[requestId];//👉 User claims their withdrawal using request ID
        require(
            req.usdmAmount > 0
                && msg.sender == req.owner
                && block.timestamp >= req.cooldownEnd,
            "invalid claim"
        );
        uint256 amount = req.usdmAmount;//👉 Store how much to pay
        delete redeemRequests[requestId];//👉 Remove request (cannot reuse)
        _removeUserRedeemId(req.owner, requestId);//👉 Clean user’s request tracking
 // @audit why we burn again we delate requestId
        usdm.burn(amount);//👉 Destroy user's claim token  User is no longer claiming money
        IRedeemEscrow(redeemEscrow).payOut(msg.sender, amount);//👉 Escrow sends real USDC to user
        emit RedeemClaimed(requestId, msg.sender, amount);//👉 Log withdrawal
    }//*Done

    // ═══════════════════════════════════════════════════════════
    //                 OPERATOR OPERATIONS
    // ═══════════════════════════════════════════════════════════

    // ─── Bridge (EVM ↔ L1) ──────────────────────────────────
    // NOTE: Once the vault contract account supports Portfolio Margin,
    // all positions will be held by the vault directly and multisigVault
    // will be disabled.
    function keeperBridge(BridgeTarget target) external onlyOperator requireWired whenNotPaused whenOperatorNotPaused {//This function sends USDC from this vault (EVM side) to L1 for trading/hedging.
        require(block.timestamp >= lastBridgeTimestamp + config.bridgeInterval(), "too early");// 👉 Prevents too frequent bridging       bridgeInterval = 6 hours;
        uint256 amount = netBridgeable();//👉 Calculates how much USDC is free to send ,,,👉 Example: Vault has 1000 USDC, 300 reserved → send 700
        require(amount > 0, "nothing to bridge");
        address recipient = (target == BridgeTarget.Multisig && multisigVaultEnabled && multisigVault != address(0))//“L1-এ টাকা যাবে কোথায়?”//1️⃣ target == BridgeTarget.Multisig 👉 operator manually বলছে:“আমি multisig-এ পাঠাতে চাই” ,,2️⃣ multisigVaultEnabled 👉 protocol allow করছে কিনা ,,3️⃣ multisigVault != address(0) 👉 address valid কিনা//recipient = 0xABC  👉 টাকা যাবে multisig wallet-এ
            ? multisigVault//“Multisig ঠিক থাকলে → ওখানে পাঠাও
            : address(this);//না হলে → নিজের contract-এই রাখো”
        outstandingL1Principal += amount;//“L1-এ কত টাকা পাঠানো হয়েছে (active trading money) — সেটা track করা”
        lastBridgeTimestamp = block.timestamp;//“শেষ কবে bridge করা হয়েছে — future cooldown check এর জন্য”
        usdc.forceApprove(coreDepositWallet, amount);//Vault → permission দিচ্ছে coreDepositWallet-কে যেন সে USDC নিতে পারে
        ICoreDepositWallet(coreDepositWallet).depositFor(recipient, amount, HyperCoreConstants.SPOT_DEX);// SPOT_DEX = Spot trading system  “এই fund spot trading (buy/sell) এর জন্য”//এখন actually টাকা পাঠানো হচ্ছে L1 system-এ
        emit BridgedToL1(amount);  
    }
    function bridgePrincipalFromL1(uint256 amount) external onlyOperator requireWired whenOperatorNotPaused {//👉 L1 (trading side) থেকে যতটুকু দরকার ততটুকু USDC Vault-এ ফিরিয়ে আনা//Vault balance = 200 USDC,,Users withdraw চায় = 500 USDC,,👉 shortfall = 300,,L1-এ আছে = 700 USDC
        require(
            amount > 0 && amount <= redemptionShortfall() && amount <= outstandingL1Principal,//কারণ: দরকার 300, তুমি আনতে চাচ্ছ 400,,❌ Case 2 (L1-এ এত নাই)amount = 800 L1 = 700  👉 ❌ FAIL
            "invalid bridge amount"
        );
        outstandingL1Principal -= amount;//“L1-এ এখন কম টাকা আছে”
        _sendL1Bridge(amount);//L1 system → Vault-এ USDC পাঠায়
        emit PrincipalBridgedFromL1(amount);
    }//*Done

    function bridgeYieldFromL1(uint256 amount) external onlyOperator requireWired whenOperatorNotPaused {//Bring profit (yield) from L1 → back to vault (EVM).
        require(amount > 0, "zero amount");
        require(amount <= yieldShortfall(), "yield shortfall");//তুমি যত নিতে চাও ≤ available yield//এখনো L1 এ থাকা yield (remaining profit)
        _sendL1Bridge(amount);//L1 → Vault USDC transfer
        emit YieldBridgedFromL1(amount);
    }

    // ─── Hedge execution ────────────────────────────────────

    function executeHedge(uint256 batchId, ActionEncoder.HedgeParams calldata params)
        external
        onlyOperator
        whenOperatorNotPaused
    {
        require(params.size > 0, "zero size");
        _requireHedgePair(params.perpAsset, params.spotAsset);

        ActionEncoder.sendBuySpot(params);
        ActionEncoder.sendShortPerp(params);

        // Under PM, Vault's new spot balance auto-supplies into 0x811 → register
        // so Accountant's strict supplied reads don't revert. Notify with HL token_index
        // (from Config), NOT `params.spotAsset` (which is pair_asset_id).
        if (pmEnabled && accountant != address(0)) {
            uint64 spotToken = uint64(config.perpToSpot(params.perpAsset));
            MonetrixAccountant(accountant).notifyVaultSupply(spotToken, params.perpAsset);
        }

        emit HedgeExecuted(batchId, params.spotAsset, params.perpAsset, params.size);
    }

    function closeHedge(ActionEncoder.CloseParams calldata params) external onlyOperator whenOperatorNotPaused {
        _requireHedgePair(params.perpAsset, params.spotAsset);

        ActionEncoder.sendSellSpot(params);
        ActionEncoder.sendClosePerp(params);

        emit HedgeClosed(params.positionId, params.spotAsset, params.size);
    }

    function repairHedge(uint256 positionId, ActionEncoder.RepairParams calldata params)
        external
        onlyOperator
        whenOperatorNotPaused
    {
        _requireRepairAsset(params.asset, params.isPerp);

        ActionEncoder.sendRepairAction(params);

        emit HedgeRepaired(positionId, params.residualBps);
    }

    // ─── HLP strategy ───────────────────────────────────────

    function depositToHLP(uint64 usdAmount) external onlyOperator whenOperatorNotPaused {
        require(usdAmount > 0, "zero amount");
        require(hlpDepositEnabled, "HLP deposit frozen");

        ActionEncoder.sendVaultDeposit(HyperCoreConstants.HLP_VAULT, usdAmount);
        emit HlpDeposited(usdAmount);
    }

    function setHlpDepositEnabled(bool enabled) external onlyOperator whenOperatorNotPaused {
        hlpDepositEnabled = enabled;
        emit HlpDepositEnabledUpdated(enabled);
    }

    function withdrawFromHLP(uint64 usdAmount) external onlyOperator whenOperatorNotPaused {
        require(usdAmount > 0, "zero amount");

        PrecompileReader.VaultEquity memory eq =
            PrecompileReader.vaultEquity(address(this), HyperCoreConstants.HLP_VAULT);
        require(uint256(usdAmount) <= uint256(eq.equity), "exceeds hlp equity");
        // `lockedUntil` is ms-epoch; L1 silently drops withdraws during lock.
        require(
            block.timestamp * 1000 >= uint256(eq.lockedUntil),
            "HLP still locked"
        );

        ActionEncoder.sendVaultWithdraw(HyperCoreConstants.HLP_VAULT, usdAmount);
        emit HlpWithdrawn(usdAmount);
    }

    // ─── BLP (Borrow/Lend Pool) ─────────────────────────────

    /// @notice Supply `l1Amount` of `token` into HL's BLP (action 15 op=0). L1 8-dp wei.
    function supplyToBlp(uint64 token, uint64 l1Amount) external onlyOperator whenOperatorNotPaused {
        require(l1Amount > 0, "zero amount");
        ActionEncoder.sendSupply(token, l1Amount);
        if (accountant != address(0)) {
            uint32 perpIndex = 0;
            if (token != uint64(HyperCoreConstants.USDC_TOKEN_INDEX)) {
                // Whitelist map is authoritative — BTC-PERP is index 0.
                require(config.isSpotWhitelisted(uint32(token)), "spot not whitelisted");
                perpIndex = config.spotToPerp(uint32(token));
            }
            MonetrixAccountant(accountant).notifyVaultSupply(token, perpIndex);
        }
        emit BlpSupplied(token, l1Amount);
    }

    /// @notice Withdraw from BLP back to spot (action 15 op=1). `l1Amount=0` means max.
    function withdrawFromBlp(uint64 token, uint64 l1Amount) external onlyOperator whenOperatorNotPaused {
        ActionEncoder.sendWithdrawSupply(token, l1Amount);
        emit BlpWithdrawn(token, l1Amount);
    }

    // ─── Settlement + Yield ─────────────────────────────────

    /// @notice Atomic all-or-nothing settle. Keeper submits `proposedYield`
    ///         (phantom-excluded off-chain); Accountant enforces 4 gates
    ///         (initialized / interval / distributable / annualized) and Vault
    ///         enforces EVM USDC sufficiency. On success the full
    ///         `proposedYield` moves to YieldEscrow; otherwise tx reverts.
    /// @dev Only `shortfall` is reserved here. `bridgeRetentionAmount` is a
    ///      bridge-to-L1 working balance (see `netBridgeable`); it is NOT a
    ///      solvency invariant and must not block yield routing.
    function settle(uint256 proposedYield) external onlyOperator requireWired nonReentrant whenNotPaused whenOperatorNotPaused {
        require(proposedYield > 0, "zero yield");

        uint256 vaultBal = usdc.balanceOf(address(this));
        uint256 shortfall_ = IRedeemEscrow(redeemEscrow).shortfall();
        uint256 available = vaultBal > shortfall_ ? vaultBal - shortfall_ : 0;
        require(available >= proposedYield, "insufficient EVM USDC");

        IMonetrixAccountant(accountant).settleDailyPnL(proposedYield);
        usdc.safeTransfer(yieldEscrow, proposedYield);
        emit YieldCollected(proposedYield);
    }

    function distributeYield() external nonReentrant onlyOperator requireWired whenNotPaused whenOperatorNotPaused {
        uint256 totalYield = IYieldEscrow(yieldEscrow).balance();
        require(totalYield > 0, "no yield");

        uint256 balBefore = usdc.balanceOf(address(this));
        IYieldEscrow(yieldEscrow).pullForDistribution(totalYield);
        require(usdc.balanceOf(address(this)) >= balBefore + totalYield, "pull");

        uint256 userShare = (totalYield * config.userYieldBps()) / 10000;
        uint256 insuranceShare = (totalYield * config.insuranceYieldBps()) / 10000;

        // Empty-vault yield would be captured by next depositor (L1-H1); reroute to foundation.
        if (userShare > 0 && susdm.totalSupply() == 0) {
            userShare = 0;
        }

        uint256 foundationShare = totalYield - userShare - insuranceShare;

        if (userShare > 0) {
            usdm.mint(address(this), userShare);
            IERC20(address(usdm)).forceApprove(address(susdm), userShare);
            susdm.injectYield(userShare);
        }

        if (insuranceShare > 0) {
            address insuranceFundAddr = config.insuranceFund();
            require(insuranceFundAddr != address(0), "zero if");
            InsuranceFund _insuranceFund = InsuranceFund(insuranceFundAddr);
            usdc.forceApprove(address(_insuranceFund), insuranceShare);
            _insuranceFund.deposit(insuranceShare);
        }
        if (foundationShare > 0) {
            address foundationAddr = config.foundation();
            require(foundationAddr != address(0), "zero fdn");
            usdc.safeTransfer(foundationAddr, foundationShare);
        }

        emit YieldDistributed(totalYield, userShare, insuranceShare, foundationShare);
    }

    // ─── Fund routing (Vault ↔ RedeemEscrow) ────────────────

    function fundRedemptions(uint256 amount) external onlyOperator requireWired whenOperatorNotPaused {
        uint256 sf = IRedeemEscrow(redeemEscrow).shortfall();
        if (sf == 0) return;
        uint256 toFund = amount == 0 ? sf : amount;
        require(toFund <= sf, "exceeds shortfall");
        uint256 vaultBal = usdc.balanceOf(address(this));
        uint256 toTransfer = toFund < vaultBal ? toFund : vaultBal;
        require(toTransfer > 0, "nothing to fund");
        usdc.safeTransfer(redeemEscrow, toTransfer);
        emit RedemptionsFunded(toTransfer);
    }

    function reclaimFromRedeemEscrow(uint256 amount) external onlyOperator requireWired whenOperatorNotPaused {
        require(amount > 0, "zero amount");
        IRedeemEscrow(redeemEscrow).reclaimTo(address(this), amount);
        emit RedeemEscrowReclaimed(amount);
    }

    // ═══════════════════════════════════════════════════════════
    //                  GUARDIAN OPERATIONS
    // ═══════════════════════════════════════════════════════════

    function pause() external onlyGuardian {
        _pause();
    }

    function unpause() external onlyGuardian {
        _unpause();
    }

    /// @notice Halt every operator-driven mutation (hedge/HLP/BLP/bridges/yield/escrow).
    ///         User fund I/O stays on the independent `paused` flag.
    function pauseOperator() external onlyGuardian {
        operatorPaused = true;
        emit OperatorPaused(msg.sender);
    }

    function unpauseOperator() external onlyGuardian {
        operatorPaused = false;
        emit OperatorUnpaused(msg.sender);
    }

    // ═══════════════════════════════════════════════════════════
    //                  GOVERNOR OPERATIONS
    // ═══════════════════════════════════════════════════════════

    /// @dev Emergency escape hatches DO NOT check either pause flag. They exist precisely
    ///      to recover from states where the operator pipeline is suspect / halted —
    ///      gating them by pause would defeat their purpose. Governor 24h timelock is
    ///      the guard.
    function emergencyRawAction(bytes calldata data) external onlyGovernor {
        ICoreWriter(HyperCoreConstants.CORE_WRITER).sendRawAction(data);
        emit EmergencyActionSent(msg.sender, keccak256(data));
    }

    function emergencyBridgePrincipalFromL1(uint256 amount) external onlyGovernor {
        require(amount > 0 && amount <= outstandingL1Principal, "invalid bridge amount");
        outstandingL1Principal -= amount;
        _sendL1Bridge(amount);
        emit PrincipalBridgedFromL1(amount);
    }

    function setAccountant(address _accountant) external onlyGovernor {
        require(_accountant != address(0), "zero acc");
        accountant = _accountant;
        emit AccountantUpdated(_accountant);
    }

    function setMultisigVault(address _multisig) external onlyGovernor {
        if (_multisig == address(0)) {
            require(!multisigVaultEnabled, "multi on");
        }
        multisigVault = _multisig;
        emit MultisigVaultUpdated(_multisig);
    }

    function setMultisigVaultEnabled(bool _enabled) external onlyGovernor {
        if (_enabled) {
            require(multisigVault != address(0), "no multi");
        }
        multisigVaultEnabled = _enabled;
    }

    function setRedeemEscrow(address _escrow) external onlyGovernor {
        require(_escrow != address(0), "zero address");
        redeemEscrow = _escrow;
        emit RedeemEscrowUpdated(_escrow);
    }

    function setYieldEscrow(address _escrow) external onlyGovernor {
        require(_escrow != address(0), "zero address");
        yieldEscrow = _escrow;
        emit YieldEscrowUpdated(_escrow);
    }

    function setBridgeRetentionAmount(uint256 amount) external onlyGovernor {
        bridgeRetentionAmount = amount;
        emit BridgeRetentionAmountUpdated(amount);
    }

    /// @notice Flip after PM is activated on Vault's L1 account; gates the 0x811 read in `_sendL1Bridge`.
    function setPmEnabled(bool enabled) external onlyGovernor {
        pmEnabled = enabled;
        emit PmEnabledUpdated(enabled);
    }

    // ═══════════════════════════════════════════════════════════
    //                      INTERNAL
    // ═══════════════════════════════════════════════════════════

    /// @dev Checks L1 USDC (spot + supplied when PM on) covers `amount` before SEND_ASSET; avoids silent L1 drop when hedge is still locked.
    function _sendL1Bridge(uint256 amount) internal {// ❗ এই function verify করে:,,“L1-এ সত্যি এই amount আছে তো?”
        uint64 usdcToken = uint64(HyperCoreConstants.USDC_TOKEN_INDEX);//“L1 system-এ USDC কোন token index-এ আছে সেটা নাও”,,এটা একটা constant value (library থেকে আসছে),,USDC_TOKEN_INDEX = 1;,,👉 এখানে token address use করে না
        uint256 l1Available = uint256(PrecompileReader.spotBalance(address(this), usdcToken).total);//Vault-এর L1 account-এ direct USDC balance কত আছে,, Spot balance = 700 USDC//👉 “L1-এ আসলে enough USDC আছে কিনা check করে তারপর bridge করো”
        if (pmEnabled) {//collateral count হবে কিনা 👉 যদি Portfolio Margin ON থাকে: ,,usable = spot + supplied,,usable = spot only,, //👉 না থাকলে:usable = spot only            //👉 suppliedBalance normally locked collateral
            l1Available += uint256(PrecompileReader.suppliedBalance(address(this), usdcToken));//✅ PM ON ->l1Available = 300 + 400 = 700
        } 
        require(
            l1Available >= TokenMath.usdcEvmToL1Wei(amount),//👉 “তুমি যত amount bridge করতে চাও…”,, 👉 “L1-এ available amount ≥ সেই amount হতে হবে”
            "L1 USDC insufficient (unwind hedge or wait for settlement)"//“L1-এ enough free USDC নাই”
        );
        ActionEncoder.sendBridgeToL1(amount);//👉 এখন actual bridge call হচ্ছে
    }//*Done

    /// @dev `spotAsset` is the HL limit-order asset for the spot leg (= 10000 + pair_index),
    ///      NOT the token_index. See `MonetrixConfig.TradeableAsset` for the distinction.
    function _requireHedgePair(uint32 perpAsset, uint32 spotAsset) internal view {
        require(config.isPerpWhitelisted(perpAsset), "perp not whitelisted");
        require(config.perpToSpotPairAssetId(perpAsset) == spotAsset, "spot/perp mismatch");
    }

    /// @dev For `isPerp=false`, `asset` is the HL pair_asset_id (= 10000 + pair_index).
    function _requireRepairAsset(uint32 asset, bool isPerp) internal view {
        if (isPerp) {
            require(config.isPerpWhitelisted(asset), "perp not whitelisted");
        } else {
            require(config.isSpotPairAssetIdWhitelisted(asset), "spot pair not wl");
        }
    }

    function _removeUserRedeemId(address user, uint256 requestId) private {//Remove a request ID from user’s list
        uint256[] storage ids = _userRedeemIds[user];//👉 Get the list of all redeem requests for this user
        uint256 len = ids.length;//👉 Get total number of requests
        for (uint256 i = 0; i < len; i++) {//👉 Loop through all request IDs
            if (ids[i] == requestId) {//👉 Find the matching request ID
                ids[i] = ids[len - 1];//Replace with last → [5, 12, 12] =[5, 12]//👉 Order is NOT preserved
                ids.pop();//👉 Remove the last element
                return;//👉 Stop after removal
            }
        }
    }

    // ═══════════════════════════════════════════════════════════
    //                       VIEW
    // ═══════════════════════════════════════════════════════════

    function netBridgeable() public view returns (uint256) {//This function calculates how much USDC is safe to send to L1 (after keeping required reserves).
        uint256 bal = usdc.balanceOf(address(this));//👉 Get total USDC in the vault,,Vault = 1000 USDC
        uint256 sf = IRedeemEscrow(redeemEscrow).shortfall();//👉 sf = shortfall (missing money),, “Protocol-এর কাছে এখন 200 USDC কম আছে users-দের দিতে”  //balance = 1000 , shortfall = 200 ,  retention = 100
        uint256 reserved = sf + bridgeRetentionAmount;//reserved = 200 + 100 = 300
        return bal > reserved ? bal - reserved : 0;//bal > reserved ?1000 > 300 → YES  ,,return 1000 - 300 = 700
    }//*Done

    function redemptionShortfall() public view returns (uint256) {
        if (redeemEscrow == address(0)) return 0;
        return IRedeemEscrow(redeemEscrow).shortfall();
    }

    function yieldShortfall() public view returns (uint256) {//(মানে: কত profit এখনো L1 এ পড়ে আছে)
        if (accountant == address(0)) return 0;
        int256 s = IMonetrixAccountant(accountant).surplus();//int256 s = IMonetrixAccountant(accountant).surplus();
        if (s <= 0) return 0;//👉 profit নাই → return 0
        uint256 yield = uint256(s);//👉 surplus → yield হিসেবে treat করা
        uint256 vaultBal = usdc.balanceOf(address(this));//👉 Vault এ current USDC
        uint256 res = IRedeemEscrow(redeemEscrow).shortfall() + bridgeRetentionAmount;//👉 reserved amount:,,  shortfall = users withdraw pending,,retention = minimum reserve
        uint256 available = vaultBal > res ? vaultBal - res : 0;//👉 Vault থেকে usable USDC: available = vaultBal - reserved
        return yield > available ? yield - available : 0;//yieldShortfall = total yield - already available in vault
    }//*Done



    function canKeeperBridge() external view returns (bool) {
        if (redeemEscrow == address(0)) return false;
        return block.timestamp >= lastBridgeTimestamp + config.bridgeInterval()
            && netBridgeable() > 0;
    }

    struct RedeemRequestDetail {
        uint256 requestId;
        uint256 usdmAmount;
        uint256 cooldownEnd;
    }

    function getUserRedeemIds(address user) external view returns (uint256[] memory) {
        return _userRedeemIds[user];
    }

    function getUserRedeemRequests(address user) external view returns (RedeemRequestDetail[] memory) {
        uint256[] memory ids = _userRedeemIds[user];
        RedeemRequestDetail[] memory details = new RedeemRequestDetail[](ids.length);
        for (uint256 i = 0; i < ids.length; i++) {
            RedeemRequest memory req = redeemRequests[ids[i]];
            details[i] =
                RedeemRequestDetail({requestId: ids[i], usdmAmount: req.usdmAmount, cooldownEnd: req.cooldownEnd});
        }
        return details;
    }

}
