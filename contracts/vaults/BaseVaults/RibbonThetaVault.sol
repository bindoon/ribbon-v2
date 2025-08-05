// SPDX-License-Identifier: MIT
pragma solidity =0.8.4;

import {SafeMath} from "@openzeppelin/contracts/utils/math/SafeMath.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {
    SafeERC20
} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {GnosisAuction} from "../../libraries/GnosisAuction.sol";
import {
    RibbonThetaVaultStorage
} from "../../storage/RibbonThetaVaultStorage.sol";
import {Vault} from "../../libraries/Vault.sol";
import {VaultLifecycle} from "../../libraries/VaultLifecycle.sol";
import {ShareMath} from "../../libraries/ShareMath.sol";
import {ILiquidityGauge} from "../../interfaces/ILiquidityGauge.sol";
import {IVaultPauser} from "../../interfaces/IVaultPauser.sol";
import {RibbonVault} from "./base/RibbonVault.sol";

/**
 * UPGRADEABILITY: Since we use the upgradeable proxy pattern, we must observe
 * the inheritance chain closely.
 * Any changes/appends in storage variable needs to happen in RibbonThetaVaultStorage.
 * RibbonThetaVault should not inherit from any other contract aside from RibbonVault, RibbonThetaVaultStorage
 */
contract RibbonThetaVault is RibbonVault, RibbonThetaVaultStorage {
    using SafeERC20 for IERC20;
    using SafeMath for uint256;
    using ShareMath for Vault.DepositReceipt;

    /************************************************
     *  IMMUTABLES & CONSTANTS
     ***********************************************/

    /// @notice oTokenFactory is the factory contract used to spawn otokens. Used to lookup otokens.
    address public immutable OTOKEN_FACTORY;

    // The minimum duration for an option auction.
    uint256 private constant MIN_AUCTION_DURATION = 5 minutes;

    /************************************************
     *  EVENTS
     ***********************************************/

    event OpenShort(
        address indexed options,
        uint256 depositAmount,
        address indexed manager
    );

    event CloseShort(
        address indexed options,
        uint256 withdrawAmount,
        address indexed manager
    );

    event NewOptionStrikeSelected(uint256 strikePrice, uint256 delta);

    event PremiumDiscountSet(
        uint256 premiumDiscount,
        uint256 newPremiumDiscount
    );

    event AuctionDurationSet(
        uint256 auctionDuration,
        uint256 newAuctionDuration
    );

    event InstantWithdraw(
        address indexed account,
        uint256 amount,
        uint256 round
    );

    event InitiateGnosisAuction(
        address indexed auctioningToken,
        address indexed biddingToken,
        uint256 auctionCounter,
        address indexed manager
    );

    /************************************************
     *  STRUCTS
     ***********************************************/

    /**
     * @notice Initialization parameters for the vault.
     * @param _owner is the owner of the vault with critical permissions
     * @param _feeRecipient is the address to recieve vault performance and management fees
     * @param _managementFee is the management fee pct.
     * @param _performanceFee is the perfomance fee pct.
     * @param _tokenName is the name of the token
     * @param _tokenSymbol is the symbol of the token
     * @param _optionsPremiumPricer is the address of the contract with the
       black-scholes premium calculation logic
     * @param _strikeSelection is the address of the contract with strike selection logic
     * @param _premiumDiscount is the vault's discount applied to the premium
     * @param _auctionDuration is the duration of the gnosis auction
     */
    struct InitParams {
        address _owner;
        address _keeper;
        address _feeRecipient;
        uint256 _managementFee;
        uint256 _performanceFee;
        string _tokenName;
        string _tokenSymbol;
        address _optionsPremiumPricer;
        address _strikeSelection;
        uint32 _premiumDiscount;
        uint256 _auctionDuration;
    }

    /************************************************
     *  CONSTRUCTOR & INITIALIZATION
     ***********************************************/

    /**
     * @notice Initializes the contract with immutable variables
     * @param _weth is the Wrapped Ether contract
     * @param _usdc is the USDC contract
     * @param _oTokenFactory is the contract address for minting new opyn option types (strikes, asset, expiry)
     * @param _gammaController is the contract address for opyn actions
     * @param _marginPool is the contract address for providing collateral to opyn
     * @param _gnosisEasyAuction is the contract address that facilitates gnosis auctions
     */
    constructor(
        address _weth,
        address _usdc,
        address _oTokenFactory,
        address _gammaController,
        address _marginPool,
        address _gnosisEasyAuction
    )
        RibbonVault(
            _weth,
            _usdc,
            _gammaController,
            _marginPool,
            _gnosisEasyAuction
        )
    {
        require(_oTokenFactory != address(0), "!_oTokenFactory");
        OTOKEN_FACTORY = _oTokenFactory;
    }

    /**
     * @notice Initializes the OptionVault contract with storage variables.
     * @param _initParams is the struct with vault initialization parameters
     * @param _vaultParams is the struct with vault general data
     */
    function initialize(
        InitParams calldata _initParams,
        Vault.VaultParams calldata _vaultParams
    ) external initializer {
        baseInitialize(
            _initParams._owner,
            _initParams._keeper,
            _initParams._feeRecipient,
            _initParams._managementFee,
            _initParams._performanceFee,
            _initParams._tokenName,
            _initParams._tokenSymbol,
            _vaultParams
        );
        require(
            _initParams._optionsPremiumPricer != address(0),
            "!_optionsPremiumPricer"
        );
        require(
            _initParams._strikeSelection != address(0),
            "!_strikeSelection"
        );
        require(
            _initParams._premiumDiscount > 0 &&
                _initParams._premiumDiscount <
                100 * Vault.PREMIUM_DISCOUNT_MULTIPLIER,
            "!_premiumDiscount"
        );
        require(
            _initParams._auctionDuration >= MIN_AUCTION_DURATION,
            "!_auctionDuration"
        );
        optionsPremiumPricer = _initParams._optionsPremiumPricer;
        strikeSelection = _initParams._strikeSelection;
        premiumDiscount = _initParams._premiumDiscount;
        auctionDuration = _initParams._auctionDuration;
    }

    /************************************************
     *  SETTERS
     ***********************************************/

    /**
     * @notice Sets the new discount on premiums for options we are selling
     * @param newPremiumDiscount is the premium discount
     */
    function setPremiumDiscount(uint256 newPremiumDiscount)
        external
        onlyKeeper
    {
        require(
            newPremiumDiscount > 0 &&
                newPremiumDiscount <= 100 * Vault.PREMIUM_DISCOUNT_MULTIPLIER,
            "Invalid discount"
        );

        emit PremiumDiscountSet(premiumDiscount, newPremiumDiscount);

        premiumDiscount = newPremiumDiscount;
    }

    /**
     * @notice Sets the new auction duration
     * @param newAuctionDuration is the auction duration
     */
    function setAuctionDuration(uint256 newAuctionDuration) external onlyOwner {
        require(
            newAuctionDuration >= MIN_AUCTION_DURATION,
            "Invalid auction duration"
        );

        emit AuctionDurationSet(auctionDuration, newAuctionDuration);

        auctionDuration = newAuctionDuration;
    }

    /**
     * @notice Sets the new strike selection contract
     * @param newStrikeSelection is the address of the new strike selection contract
     */
    function setStrikeSelection(address newStrikeSelection) external onlyOwner {
        require(newStrikeSelection != address(0), "!newStrikeSelection");
        strikeSelection = newStrikeSelection;
    }

    /**
     * @notice Sets the new options premium pricer contract
     * @param newOptionsPremiumPricer is the address of the new strike selection contract
     */
    function setOptionsPremiumPricer(address newOptionsPremiumPricer)
        external
        onlyOwner
    {
        require(
            newOptionsPremiumPricer != address(0),
            "!newOptionsPremiumPricer"
        );
        optionsPremiumPricer = newOptionsPremiumPricer;
    }

    /**
     * @notice Optionality to set strike price manually
     * @param strikePrice is the strike price of the new oTokens (decimals = 8)
     */
    function setStrikePrice(uint128 strikePrice) external onlyOwner {
        require(strikePrice > 0, "!strikePrice");
        overriddenStrikePrice = strikePrice;
        lastStrikeOverrideRound = vaultState.round;
    }

    /**
     * @notice Sets the new liquidityGauge contract for this vault
     * @param newLiquidityGauge is the address of the new liquidityGauge contract
     */
    function setLiquidityGauge(address newLiquidityGauge) external onlyOwner {
        liquidityGauge = newLiquidityGauge;
    }

    /**
     * @notice Sets the new optionsPurchaseQueue contract for this vault
     * @param newOptionsPurchaseQueue is the address of the new optionsPurchaseQueue contract
     */
    function setOptionsPurchaseQueue(address newOptionsPurchaseQueue)
        external
        onlyOwner
    {
        optionsPurchaseQueue = newOptionsPurchaseQueue;
    }

    /**
     * @notice Sets oToken Premium
     * @param minPrice is the new oToken Premium in the units of 10**18
     */
    function setMinPrice(uint256 minPrice) external onlyKeeper {
        require(minPrice > 0, "!minPrice");
        currentOtokenPremium = minPrice;
    }

    /**
     * @notice Sets the new Vault Pauser contract for this vault
     * @param newVaultPauser is the address of the new vaultPauser contract
     */
    function setVaultPauser(address newVaultPauser) external onlyOwner {
        vaultPauser = newVaultPauser;
    }

    /************************************************
     *  VAULT OPERATIONS
     ***********************************************/

    /**
     * @notice Withdraws the assets on the vault using the outstanding `DepositReceipt.amount`
     * @param amount is the amount to withdraw
     */
    function withdrawInstantly(uint256 amount) external nonReentrant {
        Vault.DepositReceipt storage depositReceipt =
            depositReceipts[msg.sender];

        uint256 currentRound = vaultState.round;
        require(amount > 0, "!amount");
        require(depositReceipt.round == currentRound, "Invalid round");

        uint256 receiptAmount = depositReceipt.amount;
        require(receiptAmount >= amount, "Exceed amount");

        // Subtraction underflow checks already ensure it is smaller than uint104
        depositReceipt.amount = uint104(receiptAmount.sub(amount));
        vaultState.totalPending = uint128(
            uint256(vaultState.totalPending).sub(amount)
        );

        emit InstantWithdraw(msg.sender, amount, currentRound);

        transferAsset(msg.sender, amount);
    }

    /**
     * @notice Initiates a withdrawal that can be processed once the round completes
     * @param numShares is the number of shares to withdraw
     */
    function initiateWithdraw(uint256 numShares) external nonReentrant {
        _initiateWithdraw(numShares);
        currentQueuedWithdrawShares = currentQueuedWithdrawShares.add(
            numShares
        );
    }

    /**
     * @notice Completes a scheduled withdrawal from a past round. Uses finalized pps for the round
     */
    function completeWithdraw() external nonReentrant {
        uint256 withdrawAmount = _completeWithdraw();
        lastQueuedWithdrawAmount = uint128(
            uint256(lastQueuedWithdrawAmount).sub(withdrawAmount)
        );
    }

    /**
     * @notice Stakes a users vault shares
     * @param numShares is the number of shares to stake
     */
    function stake(uint256 numShares) external nonReentrant {
        address _liquidityGauge = liquidityGauge;
        require(_liquidityGauge != address(0)); // Removed revert msgs due to contract size limit
        require(numShares > 0);
        uint256 heldByAccount = balanceOf(msg.sender);
        if (heldByAccount < numShares) {
            _redeem(numShares.sub(heldByAccount), false);
        }
        _transfer(msg.sender, address(this), numShares);
        _approve(address(this), _liquidityGauge, numShares);
        ILiquidityGauge(_liquidityGauge).deposit(numShares, msg.sender, false);
    }

    /**
     * @notice Sets the next option the vault will be shorting, and closes the existing short.
     *         This allows all the users to withdraw if the next option is malicious.
     * 
     * 🎯 承诺并关闭当前期权：这是金库运营的核心函数，完成期权轮次转换
     * 
     * 执行流程：
     * 1️⃣ 保存当前期权地址（准备关闭）
     * 2️⃣ 构建期权关闭参数结构体
     * 3️⃣ 调用 VaultLifecycle 库创建新期权
     * 4️⃣ 更新期权状态和时间延迟
     * 5️⃣ 关闭旧期权头寸
     */
    function commitAndClose() external nonReentrant {
        // 📋 第一步：保存当前期权地址，准备关闭当前轮次
        // 这个地址可能是 address(0)（首次运行）或上一轮的期权合约地址
        address oldOption = optionState.currentOption;

        // 🏗️ 第二步：构建期权关闭参数结构体
        // 这个结构体包含创建新期权所需的所有配置信息
        VaultLifecycle.CloseParams memory closeParams =
            VaultLifecycle.CloseParams({
                OTOKEN_FACTORY: OTOKEN_FACTORY,           // 🏭 Opyn 期权工厂地址
                USDC: USDC,                               // 💵 USDC 代币地址（用于看跌期权）
                currentOption: oldOption,                 // 📋 当前期权地址（即将关闭的）
                delay: DELAY,                             // ⏰ 安全延迟时间（通常6小时）
                lastStrikeOverrideRound: lastStrikeOverrideRound,     // 🎯 上次手动覆盖执行价格的轮次
                overriddenStrikePrice: overriddenStrikePrice,         // 💰 手动覆盖的执行价格
                strikeSelection: strikeSelection,         // 🧮 执行价格选择策略合约
                optionsPremiumPricer: optionsPremiumPricer, // 📊 期权定价器合约
                premiumDiscount: premiumDiscount          // 🎫 期权销售折扣率（如5%）
            });

        // 🚀 第三步：调用核心库函数创建新期权
        // 这是整个函数的核心，委托给 VaultLifecycle 库处理复杂逻辑：
        // - 计算新期权的到期时间（下周五）
        // - 通过算法选择执行价格（Delta-based 或手动）
        // - 在 Opyn 上创建或获取期权合约
        // - 计算期权的理论溢价
        (address otokenAddress, uint256 strikePrice, uint256 delta) =
            VaultLifecycle.commitAndClose(closeParams, vaultParams, vaultState);

        // 📢 第四步：发出事件通知，记录新期权的关键信息
        // 前端和监控系统可以监听这个事件来跟踪金库状态
        emit NewOptionStrikeSelected(strikePrice, delta);

        // 📝 第五步：更新期权状态 - 设置下一个期权地址
        // 新创建的期权合约地址，将在 rollToNextOption() 中被激活
        optionState.nextOption = otokenAddress;

        // ⏰ 第六步：计算并设置期权准备时间
        // 添加安全延迟（通常6小时），让用户有时间检查新期权参数
        uint256 nextOptionReady = block.timestamp.add(DELAY);
        require(
            nextOptionReady <= type(uint32).max,    // 🛡️ 防止时间戳溢出
            "Overflow nextOptionReady"
        );
        optionState.nextOptionReadyAt = uint32(nextOptionReady);

        // 🔒 第七步：关闭旧期权头寸
        // 如果存在旧期权，处理到期结算、释放抵押品等清理工作
        _closeShort(oldOption);
    }

    /**
     * @notice Closes the existing short position for the vault.
     */
    function _closeShort(address oldOption) private {
        uint256 lockedAmount = vaultState.lockedAmount;
        if (oldOption != address(0)) {
            vaultState.lastLockedAmount = uint104(lockedAmount);
        }
        vaultState.lockedAmount = 0;

        optionState.currentOption = address(0);

        if (oldOption != address(0)) {
            uint256 withdrawAmount =
                VaultLifecycle.settleShort(GAMMA_CONTROLLER);
            emit CloseShort(oldOption, withdrawAmount, msg.sender);
        }
    }

    /**
     * @notice 🚀 启动新期权轮次的核心函数 - 将金库资金转入新的期权头寸
     * @dev 这是期权策略执行的关键函数，完成从上轮结算到新轮启动的完整流程
     * 
     * 🔄 主要执行步骤：
     * 1. 处理用户提款队列和金库份额计算
     * 2. 计算新的金库代币价格和铸造新份额
     * 3. 收取管理费和性能费
     * 4. 在 Opyn 协议中创建新的期权头寸
     * 5. 分配期权给购买队列（机构优先购买）
     * 6. 启动期权拍卖销售
     * 
     * 🛡️ 权限要求：只有 Keeper 可以调用，并且有重入保护
     */
    function rollToNextOption() external onlyKeeper nonReentrant {
        // 📊 第一步：获取当前轮次排队提款的份额数量
        // currentQueuedWithdrawShares 记录了本轮用户发起提款请求的金库代币数量
        uint256 currQueuedWithdrawShares = currentQueuedWithdrawShares;

        // 🎯 第二步：执行核心轮次转移逻辑
        // _rollToNextOption 是最复杂的内部函数，处理：
        // - 计算新的金库代币价格
        // - 为新存款铸造金库代币
        // - 计算并收取各种费用
        // - 确定新轮次的锁定资金数量
        (
            address newOption,       // 🎫 新期权合约地址（由 commitAndClose 创建）
            uint256 lockedBalance,   // 💰 新轮次锁定的资金数量（用作期权抵押品）
            uint256 queuedWithdrawAmount // 🚪 排队等待提款的资金总额
        ) =
            _rollToNextOption(
                lastQueuedWithdrawAmount,    // 上一轮遗留的待提款金额
                currQueuedWithdrawShares     // 当前轮次新增的待提款份额
            );

        // 📝 第三步：更新提款相关状态变量
        // 记录本轮次总的待提款金额（包括历史遗留 + 本轮新增）
        lastQueuedWithdrawAmount = queuedWithdrawAmount;

        // 🔄 第四步：更新金库全局提款份额统计
        // vaultState.queuedWithdrawShares 累加所有等待提款的份额
        // 这些份额在期权到期后才能真正提取资金
        uint256 newQueuedWithdrawShares =
            uint256(vaultState.queuedWithdrawShares).add(
                currQueuedWithdrawShares
            );
        ShareMath.assertUint128(newQueuedWithdrawShares); // 防止溢出
        vaultState.queuedWithdrawShares = uint128(newQueuedWithdrawShares);

        // 🔄 第五步：清零当前轮次的提款队列
        // 将本轮的提款份额转移到全局队列后，重置当前计数器
        currentQueuedWithdrawShares = 0;

        // 💾 第六步：更新金库锁定资金状态
        // lockedAmount 是当前轮次用作期权抵押品的资金数量
        ShareMath.assertUint104(lockedBalance); // 防止溢出
        vaultState.lockedAmount = uint104(lockedBalance);

        // 📢 第七步：发出期权头寸开启事件
        emit OpenShort(newOption, lockedBalance, msg.sender);

        // 🏭 第八步：在 Opyn 协议中创建实际的期权头寸
        // 这一步将锁定的资金存入 Opyn 的 Margin Pool 作为抵押品
        // 并铸造相应数量的期权代币（OToken）
        uint256 optionsMintAmount =
            VaultLifecycle.createShort(
                GAMMA_CONTROLLER,    // Opyn 控制器合约地址
                MARGIN_POOL,         // Opyn 保证金池地址  
                newOption,           // 新期权合约地址
                lockedBalance        // 抵押品数量
            );
        // 返回值：实际铸造的期权代币数量，通常等于 lockedBalance

        // 🎪 第九步：为购买队列预分配期权（机构优先购买权）
        // 将铸造期权的一定比例（默认50%）分配给 OptionsPurchaseQueue
        // 这让机构客户可以在公开拍卖之前优先购买期权
        VaultLifecycle.allocateOptions(
            optionsPurchaseQueue,                        // 购买队列合约地址
            newOption,                                   // 期权合约地址
            optionsMintAmount,                          // 总期权数量
            VaultLifecycle.QUEUE_OPTION_ALLOCATION      // 分配比例（50% = 5000）
        );
        // 例如：铸造1000个期权，分配500个给队列，剩余500个进入拍卖

        // 🔥 第十步：启动期权公开拍卖
        // 将剩余的期权通过 Gnosis Auction 进行公开竞价销售
        _startAuction();
        // 拍卖将确定期权的最终市场价格，通常持续6小时
    }

    /**
     * @notice Initiate the gnosis auction.
     */
    function startAuction() external onlyKeeper nonReentrant {
        _startAuction();
    }

    /**
     * 🔨 启动期权拍卖：配置并启动 Gnosis 拍卖，将期权出售给市场
     * 
     * 核心流程：
     * 1️⃣ 创建拍卖详情结构体
     * 2️⃣ 设置期权合约地址
     * 3️⃣ 配置拍卖基础设施
     * 4️⃣ 设置资产和定价信息
     * 5️⃣ 启动 Gnosis 拍卖并获取拍卖ID
     */
    function _startAuction() private {
        // 🏗️ 第一步：创建拍卖详情结构体
        // 这个结构体包含启动 Gnosis 拍卖所需的所有配置信息
        GnosisAuction.AuctionDetails memory auctionDetails;

        // 🎫 第二步：获取当前期权合约地址
        // 这是在 rollToNextOption() 中设置的，指向当前活跃的期权合约
        address currentOtoken = optionState.currentOption;

        // 📋 第三步：设置期权合约信息
        // 告诉 Gnosis 拍卖哪个 ERC20 代币（期权）将被拍卖
        auctionDetails.oTokenAddress = currentOtoken;
        
        // 🏛️ 第四步：设置 Gnosis 拍卖合约地址
        // GNOSIS_EASY_AUCTION 是部署的 Gnosis Easy Auction 合约地址
        // 这是拍卖的基础设施提供方
        auctionDetails.gnosisEasyAuction = GNOSIS_EASY_AUCTION;
        
        // 💰 第五步：设置资产和小数位信息
        // asset: 用于竞价的资产（如 USDC、ETH）
        // assetDecimals: 资产的小数位数（如 USDC=6, ETH=18）
        auctionDetails.asset = vaultParams.asset;
        auctionDetails.assetDecimals = vaultParams.decimals;
        
        // 💵 第六步：设置期权溢价（最低竞价价格）
        // currentOtokenPremium 是通过 Black-Scholes 模型计算的期权理论价值
        // 这将作为拍卖的起始价格或最低价格
        auctionDetails.oTokenPremium = currentOtokenPremium;
        
        // ⏰ 第七步：设置拍卖持续时间
        // auctionDuration 通常为 6 小时（21600 秒）
        // 在此期间用户可以提交竞价
        auctionDetails.duration = auctionDuration;

        // 🚀 第八步：启动 Gnosis 拍卖并保存拍卖ID
        // 委托给 VaultLifecycle 库函数执行实际的拍卖启动逻辑
        // 返回的 optionAuctionID 用于后续跟踪和结算拍卖
        optionAuctionID = VaultLifecycle.startAuction(auctionDetails);
    }

    /**
     * @notice Sell the allocated options to the purchase queue post auction settlement
     */
    function sellOptionsToQueue() external onlyKeeper nonReentrant {
        VaultLifecycle.sellOptionsToQueue(
            optionsPurchaseQueue,
            GNOSIS_EASY_AUCTION,
            optionAuctionID
        );
    }

    /**
     * @notice Burn the remaining oTokens left over from gnosis auction.
     */
    function burnRemainingOTokens() external onlyKeeper nonReentrant {
        uint256 unlockedAssetAmount =
            VaultLifecycle.burnOtokens(
                GAMMA_CONTROLLER,
                optionState.currentOption
            );

        vaultState.lockedAmount = uint104(
            uint256(vaultState.lockedAmount).sub(unlockedAssetAmount)
        );
    }

    /**
     * @notice Recovery function that returns an ERC20 token to the recipient
     * @param token is the ERC20 token to recover from the vault
     * @param recipient is the recipient of the recovered tokens
     */
    function recoverTokens(address token, address recipient)
        external
        onlyOwner
    {
        require(token != vaultParams.asset, "Vault asset not recoverable");
        require(token != address(this), "Vault share not recoverable");
        require(recipient != address(this), "Recipient cannot be vault");

        IERC20(token).safeTransfer(
            recipient,
            IERC20(token).balanceOf(address(this))
        );
    }

    /**
     * @notice pause a user's vault position
     */
    function pausePosition() external {
        address _vaultPauserAddress = vaultPauser;
        require(_vaultPauserAddress != address(0)); // Removed revert msgs due to contract size limit
        _redeem(0, true);
        uint256 heldByAccount = balanceOf(msg.sender);
        _approve(msg.sender, _vaultPauserAddress, heldByAccount);
        IVaultPauser(_vaultPauserAddress).pausePosition(
            msg.sender,
            heldByAccount
        );
    }
}
