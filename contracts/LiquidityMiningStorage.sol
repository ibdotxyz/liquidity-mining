// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

contract LiquidityMiningStorage {
    /// @notice The comptroller that wants to distribute rewards.
    address public comptroller;

    /// @notice The support reward tokens.
    address[] public rewardTokens;

    /// @notice The support reward tokens.
    mapping(address => bool) public rewardTokensMap;

    struct RewardSpeed {
        uint speed;
        uint start;
        uint end;
    }

    /// @notice The reward speeds of each reward token for every supply market
    mapping(address => mapping(address => RewardSpeed)) public rewardSupplySpeeds;

    /// @notice The reward speeds of each reward token for every borrow market
    mapping(address => mapping(address => RewardSpeed)) public rewardBorrowSpeeds;

    struct RewardState {
        uint index;
        uint timestamp;
    }

    /// @notice The market reward supply state for each market
    mapping(address => mapping(address => RewardState)) public rewardSupplyState;

    /// @notice The market reward borrow state for each market
    mapping(address => mapping(address => RewardState)) public rewardBorrowState;

    /// @notice The supply index for each market for each supplier as of the last time they accrued rewards
    mapping(address => mapping(address => mapping(address => uint))) public rewardSupplierIndex;

    /// @notice The borrow index for each market for each borrower as of the last time they accrued rewards
    mapping(address => mapping(address => mapping(address => uint))) public rewardBorrowerIndex;

    /// @notice The reward accrued but not yet transferred to each user
    mapping(address => mapping(address => uint)) public rewardAccrued;

    /// @notice The debtors who can't claim rewards until their bad debts are repaid.
    mapping(address => bool) public debtors;

    /// @notice The reward delegate receiver of users.
    mapping(address => address) public rewardReceivers;
}
