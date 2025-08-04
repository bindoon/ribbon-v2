// SPDX-License-Identifier: MIT
pragma solidity =0.8.4;

library Vault {
    /************************************************
     *  IMMUTABLES & CONSTANTS
     ***********************************************/

    // Fees are 6-decimal places. For example: 20 * 10**6 = 20%
    uint256 internal constant FEE_MULTIPLIER = 10**6;

    // Premium discount has 1-decimal place. For example: 80 * 10**1 = 80%. Which represents a 20% discount.
    uint256 internal constant PREMIUM_DISCOUNT_MULTIPLIER = 10;

    // Otokens have 8 decimal places.
    uint256 internal constant OTOKEN_DECIMALS = 8;

    // Percentage of funds allocated to options is 2 decimal places. 10 * 10**2 = 10%
    uint256 internal constant OPTION_ALLOCATION_MULTIPLIER = 10**2;

    // Placeholder uint value to prevent cold writes
    uint256 internal constant PLACEHOLDER_UINT = 1;

    struct VaultParams {
        // Option type the vault is selling
        bool isPut; // 是否是看跌期权
        // Token decimals for vault shares
        uint8 decimals; // 代币的小数位数
        // Asset used in Theta / Delta Vault
        address asset; // 资产地址
        // Underlying asset of the options sold by vault
        address underlying; // 底层资产地址
        // Minimum supply of the vault shares issued, for ETH it's 10**10
        uint56 minimumSupply; // 最小供应量
        // Vault cap
        uint104 cap; // 最大容量
    }

    struct OptionState {
        // Option that the vault is shorting / longing in the next cycle
        address nextOption; // 下一个期权合约地址
        // Option that the vault is currently shorting / longing
        address currentOption; // 当前期权合约地址
        // The timestamp when the `nextOption` can be used by the vault
        uint32 nextOptionReadyAt; // 下一个期权合约可以使用的最早时间
    }

    struct VaultState {
        // 32 byte slot 1
        //  Current round number. `round` represents the number of `period`s elapsed.
        uint16 round; // 当前轮次
        // Amount that is currently locked for selling options
        uint104 lockedAmount; // 当前锁定的金额
        // Amount that was locked for selling options in the previous round
        // used for calculating performance fee deduction
        uint104 lastLockedAmount; // 上一轮锁定的金额
        // 32 byte slot 2
        // Stores the total tally of how much of `asset` there is
        // to be used to mint rTHETA tokens
        uint128 totalPending; // 待处理的金额
        // Total amount of queued withdrawal shares from previous rounds (doesn't include the current round)
        uint128 queuedWithdrawShares; // 待提取的份额
    }

    struct DepositReceipt {
        // Maximum of 65535 rounds. Assuming 1 round is 7 days, maximum is 1256 years.
        uint16 round; // 轮次
        // Deposit amount, max 20,282,409,603,651 or 20 trillion ETH deposit
        uint104 amount; // 存款金额
        // Unredeemed shares balance
        uint128 unredeemedShares; // 未赎回的份额
    }

    struct Withdrawal {
        // Maximum of 65535 rounds. Assuming 1 round is 7 days, maximum is 1256 years.
        uint16 round; // 轮次
        // Number of shares withdrawn
        uint128 shares; // 提取的份额
    }

    struct AuctionSellOrder {
        // Amount of `asset` token offered in auction
        uint96 sellAmount; // 出售的金额
        // Amount of oToken requested in auction
        uint96 buyAmount; // 请求的期权合约数量
        // User Id of delta vault in latest gnosis auction
        uint64 userId; // 用户ID
    }
}
