// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./LiquidityMiningStorage.sol";
import "./interfaces/ComptrollerInterface.sol";
import "./interfaces/CTokenInterface.sol";
import "./interfaces/LiquidityMiningInterface.sol";
import "./libraries/SafeERC20.sol";

contract LiquidityMining is LiquidityMiningStorage, LiquidityMiningInterface {
    using SafeERC20 for IERC20;

    uint internal constant initialIndex = 1e18;
    address public constant ethAddress = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    /**
     * @notice Emitted when a supplier's reward supply index is updated
     */
    event UpdateSupplierRewardIndex(
        address indexed rewardToken,
        address indexed cToken,
        address indexed supplier,
        uint rewards,
        uint supplyIndex
    );

    /**
     * @notice Emitted when a borrower's reward borrower index is updated
     */
    event UpdateBorowerRewardIndex(
        address indexed rewardToken,
        address indexed cToken,
        address indexed borrower,
        uint rewards,
        uint borrowIndex
    );

    /**
     * @notice Emitted when a market's reward supply speed is updated
     */
    event UpdateSupplyRewardSpeed(
        address indexed rewardToken,
        address indexed cToken,
        uint indexed speed,
        uint start,
        uint end
    );

    /**
     * @notice Emitted when a market's reward borrow speed is updated
     */
    event UpdateBorrowRewardSpeed(
        address indexed rewardToken,
        address indexed cToken,
        uint indexed speed,
        uint start,
        uint end
    );

    /**
     * @notice Emitted when rewards are transferred to a user
     */
    event TransferReward(
        address indexed rewardToken,
        address indexed account,
        uint indexed amount
    );

    /**
     * @notice Emitted when a debtor is updated
     */
    event UpdateDebtor(
        address indexed account,
        bool indexed isDebtor
    );

    /**
     * @notice Initialize the contract with admin and comptroller
     */
    constructor(address _admin, address _comptroller) {
        admin = _admin;
        comptroller = _comptroller;
    }

    /**
     * @notice Modifier used internally that assures the sender is the admin.
     */
    modifier onlyAdmin() {
        require(msg.sender == admin, "only admin could perform the action");
        _;
    }

    /**
     * @notice Modifier used internally that assures the sender is the comptroller.
     */
    modifier onlyComptroller() {
        require(msg.sender == comptroller, "only comptroller could perform the action");
        _;
    }

    /**
     * @notice Contract might receive ETH as one of the LM rewards.
     */
    receive() external payable {}

    /* Comptroller functions */

    /**
     * @notice Accrue rewards to the market by updating the supply index and calculate rewards accrued by suppliers
     * @param cToken The market whose supply index to update
     * @param suppliers The related suppliers
     */
    function updateSupplyIndex(address cToken, address[] memory suppliers) external override onlyComptroller {
        // Distribute the rewards right away.
        updateSupplyIndexInternal(rewardTokens, cToken, suppliers, true);
    }

    /**
     * @notice Accrue rewards to the market by updating the borrow index and calculate rewards accrued by borrowers
     * @param cToken The market whose borrow index to update
     * @param borrowers The related borrowers
     */
    function updateBorrowIndex(address cToken, address[] memory borrowers) external override onlyComptroller {
        // Distribute the rewards right away.
        updateBorrowIndexInternal(rewardTokens, cToken, borrowers, true);
    }

    /* User functions */

    /**
     * @notice Return the current block number.
     * @return The current block number
     */
    function getBlockNumber() public virtual view returns (uint) {
        return block.number;
    }

    /**
     * @notice Claim all the rewards accrued by holder in all markets
     * @param holder The address to claim rewards for
     */
    function claimRewards(address holder) public override {
        address[] memory holders = new address[](1);
        holders[0] = holder;
        address[] memory allMarkets = ComptrollerInterface(comptroller).getAllMarkets();
        return claimRewards(holders, allMarkets, rewardTokens, true, true);
    }

    /**
     * @notice Claim all the rewards accrued by the holders
     * @param holders The addresses to claim rewards for
     * @param cTokens The list of markets to claim rewards in
     * @param rewards The list of reward tokens to claim
     * @param borrowers Whether or not to claim rewards earned by borrowing
     * @param suppliers Whether or not to claim rewards earned by supplying
     */
    function claimRewards(address[] memory holders, address[] memory cTokens, address[] memory rewards, bool borrowers, bool suppliers) public override {
        for (uint i = 0; i < cTokens.length; i++) {
            address cToken = cTokens[i];
            (bool isListed, , ) = ComptrollerInterface(comptroller).markets(cToken);
            require(isListed, "market must be listed");

            // Same reward generated from multiple markets could aggregate and distribute once later for gas consumption.
            if (borrowers == true) {
                updateBorrowIndexInternal(rewards, cToken, holders, false);
            }
            if (suppliers == true) {
                updateSupplyIndexInternal(rewards, cToken, holders, false);
            }
        }

        // Distribute the rewards.
        for (uint i = 0; i < rewards.length; i++) {
            for (uint j = 0; j < holders.length; j++) {
                address rewardToken = rewards[i];
                address holder = holders[j];
                rewardAccrued[rewardToken][holder] = transferReward(rewardToken, holder, rewardAccrued[rewardToken][holder]);
            }
        }
    }

    /**
     * @notice Update accounts to be debtors or not. Debtors couldn't claim rewards until their bad debts are repaid.
     * @param accounts The list of accounts to be updated
     */
    function updateDebtors(address[] memory accounts) public override {
        for (uint i = 0; i < accounts.length; i++) {
            address account = accounts[i];
            (uint err, , uint shortfall) = ComptrollerInterface(comptroller).getAccountLiquidity(account);
            require(err == 0, "failed to get account liquidity from comptroller");

            if (shortfall > 0 && !debtors[account]) {
                debtors[account] = true;
                emit UpdateDebtor(account, true);
            } else if (shortfall == 0 && debtors[account]) {
                debtors[account] = false;
                emit UpdateDebtor(account, false);
            }
        }
    }

    /* Admin functions */

    /**
     * @notice Add new reward token. Revert if the reward token has been added
     * @param rewardToken The new reward token
     */
    function _addRewardToken(address rewardToken) external onlyAdmin {
        require(!rewardTokensMap[rewardToken], "reward token has been added");
        rewardTokensMap[rewardToken] = true;
        rewardTokens.push(rewardToken);
    }

    /**
     * @notice Set cTokens reward supply speeds
     * @param rewardToken The reward token
     * @param cTokens The addresses of cTokens
     * @param speeds The list of reward speeds
     * @param starts The list of start block numbers
     * @param ends The list of end block numbers
     */
    function _setRewardSupplySpeeds(address rewardToken, address[] memory cTokens, uint[] memory speeds, uint[] memory starts, uint[] memory ends) external onlyAdmin {
        _setRewardSpeeds(rewardToken, cTokens, speeds, starts, ends, true);
    }

    /**
     * @notice Set cTokens reward borrow speeds
     * @param rewardToken The reward token
     * @param cTokens The addresses of cTokens
     * @param speeds The list of reward speeds
     * @param starts The list of start block numbers
     * @param ends The list of end block numbers
     */
    function _setRewardBorrowSpeeds(address rewardToken, address[] memory cTokens, uint[] memory speeds, uint[] memory starts, uint[] memory ends) external onlyAdmin {
        _setRewardSpeeds(rewardToken, cTokens, speeds, starts, ends, false);
    }

    /* Internal functions */

    /**
     * @notice Given the reward token list, accrue rewards to the market by updating the supply index and calculate rewards accrued by suppliers
     * @param rewards The list of rewards to update
     * @param cToken The market whose supply index to update
     * @param suppliers The related suppliers
     * @param distribute Distribute the reward or not
     */
    function updateSupplyIndexInternal(address[] memory rewards, address cToken, address[] memory suppliers, bool distribute) internal {
        for (uint i = 0; i < rewards.length; i++) {
            require(rewardTokensMap[rewards[i]], "reward token not support");
            updateGlobalSupplyIndex(rewards[i], cToken);
            for (uint j = 0; j < suppliers.length; j++) {
                updateUserSupplyIndex(rewards[i], cToken, suppliers[j], distribute);
            }
        }
    }

    /**
     * @notice Given the reward token list, accrue rewards to the market by updating the borrow index and calculate rewards accrued by borrowers
     * @param rewards The list of rewards to update
     * @param cToken The market whose borrow index to update
     * @param borrowers The related borrowers
     * @param distribute Distribute the reward or not
     */
    function updateBorrowIndexInternal(address[] memory rewards, address cToken, address[] memory borrowers, bool distribute) internal {
        for (uint i = 0; i < rewards.length; i++) {
            require(rewardTokensMap[rewards[i]], "reward token not support");

            uint marketBorrowIndex = CTokenInterface(cToken).borrowIndex();
            updateGlobalBorrowIndex(rewards[i], cToken, marketBorrowIndex);
            for (uint j = 0; j < borrowers.length; j++) {
                updateUserBorrowIndex(rewards[i], cToken, borrowers[j], marketBorrowIndex, distribute);
            }
        }
    }

    /**
     * @notice Accrue rewards to the market by updating the supply index
     * @param rewardToken The reward token
     * @param cToken The market whose supply index to update
     */
    function updateGlobalSupplyIndex(address rewardToken, address cToken) internal {
        RewardState storage supplyState = rewardSupplyState[rewardToken][cToken];
        RewardSpeed memory supplySpeed = rewardSupplySpeeds[rewardToken][cToken];
        uint blockNumber = getBlockNumber();
        if (blockNumber > supplyState.block) {
            if (supplySpeed.speed == 0 || supplySpeed.start > blockNumber || supplyState.block > supplySpeed.end) {
                // 1. The reward speed is zero,
                // 2. The reward hasn't started yet,
                // 3. The supply state has handled the end of the reward,
                // just update the block number.
                supplyState.block = blockNumber;
            } else {
                // fromBlock is the max of the last update block number and the reward start block number.
                uint fromBlock = max(supplyState.block, supplySpeed.start);
                // toBlock is the min of the current block number and the reward end block number.
                uint toBlock = min(blockNumber, supplySpeed.end);
                // deltaBlocks is the block difference used for calculating the rewards.
                uint deltaBlocks = toBlock - fromBlock;
                uint rewardAccrued = deltaBlocks * supplySpeed.speed;
                uint supplyTokens = CTokenInterface(cToken).totalSupply();
                uint ratio = supplyTokens > 0 ? rewardAccrued * 1e18 / supplyTokens : 0;
                uint index = supplyState.index + ratio;
                rewardSupplyState[rewardToken][cToken] = RewardState({
                    index: index,
                    block: blockNumber
                });
            }
        }
    }

    /**
     * @notice Accrue rewards to the market by updating the borrow index
     * @param rewardToken The reward token
     * @param cToken The market whose borrow index to update
     * @param marketBorrowIndex The market borrow index
     */
    function updateGlobalBorrowIndex(address rewardToken, address cToken, uint marketBorrowIndex) internal {
        RewardState storage borrowState = rewardBorrowState[rewardToken][cToken];
        RewardSpeed memory borrowSpeed = rewardBorrowSpeeds[rewardToken][cToken];
        uint blockNumber = getBlockNumber();
        if (blockNumber > borrowState.block) {
            if (borrowSpeed.speed == 0 || blockNumber < borrowSpeed.start || borrowState.block > borrowSpeed.end) {
                // 1. The reward speed is zero,
                // 2. The reward hasn't started yet,
                // 3. The borrow state has handled the end of the reward,
                // just update the block number.
                borrowState.block = blockNumber;
            } else {
                // fromBlock is the max of the last update block number and the reward start block number.
                uint fromBlock = max(borrowState.block, borrowSpeed.start);
                // toBlock is the min of the current block number and the reward end block number.
                uint toBlock = min(blockNumber, borrowSpeed.end);
                // deltaBlocks is the block difference used for calculating the rewards.
                uint deltaBlocks = toBlock - fromBlock;
                uint rewardAccrued = deltaBlocks * borrowSpeed.speed;
                uint borrowAmount = CTokenInterface(cToken).totalBorrows() * 1e18 / marketBorrowIndex;
                uint ratio = borrowAmount > 0 ? rewardAccrued * 1e18 / borrowAmount : 0;
                uint index = borrowState.index + ratio;
                rewardBorrowState[rewardToken][cToken] = RewardState({
                    index: index,
                    block: blockNumber
                });
            }
        }
    }

    /**
     * @notice Calculate rewards accrued by a supplier and possibly transfer it to them
     * @param rewardToken The reward token
     * @param cToken The market in which the supplier is interacting
     * @param supplier The address of the supplier to distribute rewards to
     * @param distribute Distribute the reward or not
     */
    function updateUserSupplyIndex(address rewardToken, address cToken, address supplier, bool distribute) internal {
        RewardState memory supplyState = rewardSupplyState[rewardToken][cToken];
        uint supplyIndex = supplyState.index;
        uint supplierIndex = rewardSupplierIndex[rewardToken][cToken][supplier];
        rewardSupplierIndex[rewardToken][cToken][supplier] = supplyIndex;

        if (supplierIndex == 0 && supplyIndex > 0) {
            supplierIndex = initialIndex;
        }

        uint deltaIndex = supplyIndex - supplierIndex;
        uint supplierTokens = CTokenInterface(cToken).balanceOf(supplier);
        uint supplierDelta = supplierTokens * deltaIndex / 1e18;
        uint accruedAmount = rewardAccrued[rewardToken][supplier] + supplierDelta;
        if (distribute) {
            rewardAccrued[rewardToken][supplier] = transferReward(rewardToken, supplier, accruedAmount);
        } else {
            rewardAccrued[rewardToken][supplier] = accruedAmount;
        }
        emit UpdateSupplierRewardIndex(rewardToken, cToken, supplier, supplierDelta, supplyIndex);
    }

    /**
     * @notice Calculate rewards accrued by a borrower and possibly transfer it to them
     * @dev Borrowers will not begin to accrue until after the first interaction with the protocol.
     * @param rewardToken The reward token
     * @param cToken The market in which the borrower is interacting
     * @param borrower The address of the borrower to distribute rewards to
     * @param marketBorrowIndex The market borrow index
     * @param distribute Distribute the reward or not
     */
    function updateUserBorrowIndex(address rewardToken, address cToken, address borrower, uint marketBorrowIndex, bool distribute) internal {
        RewardState memory borrowState = rewardBorrowState[rewardToken][cToken];
        uint borrowIndex = borrowState.index;
        uint borrowerIndex = rewardBorrowerIndex[rewardToken][cToken][borrower];
        rewardBorrowerIndex[rewardToken][cToken][borrower] = borrowIndex;

        if (borrowerIndex > 0) {
            uint deltaIndex = borrowIndex - borrowerIndex;
            uint borrowerAmount = CTokenInterface(cToken).borrowBalanceStored(borrower) * 1e18 / marketBorrowIndex;
            uint borrowerDelta = borrowerAmount * deltaIndex / 1e18;
            uint accruedAmount = rewardAccrued[rewardToken][borrower] + borrowerDelta;
            if (distribute) {
                rewardAccrued[rewardToken][borrower] = transferReward(rewardToken, borrower, accruedAmount);
            } else {
                rewardAccrued[rewardToken][borrower] = accruedAmount;
            }
            emit UpdateBorowerRewardIndex(rewardToken, cToken, borrower, borrowerDelta, borrowIndex);
        }
    }

    /**
     * @notice Transfer rewards to the user
     * @param rewardToken The reward token
     * @param user The address of the user to transfer rewards to
     * @param amount The amount of rewards to (possibly) transfer
     * @return The amount of rewards which was NOT transferred to the user
     */
    function transferReward(address rewardToken, address user, uint amount) internal returns (uint) {
        uint remain = rewardToken == ethAddress ? address(this).balance : IERC20(rewardToken).balanceOf(address(this));
        if (amount > 0 && amount <= remain && !debtors[user]) {
            if (rewardToken == ethAddress) {
                payable(user).transfer(amount);
            } else {
                IERC20(rewardToken).safeTransfer(user, amount);
            }
            emit TransferReward(rewardToken, user, amount);
            return 0;
        }
        return amount;
    }

    /**
     * @notice Set reward speeds
     * @param rewardToken The reward token
     * @param cTokens The addresses of cTokens
     * @param speeds The list of reward speeds
     * @param starts The list of start block numbers
     * @param ends The list of end block numbers
     * @param supply It's supply speed or borrow speed
     */
    function _setRewardSpeeds(address rewardToken, address[] memory cTokens, uint[] memory speeds, uint[] memory starts, uint[] memory ends, bool supply) internal {
        uint numMarkets = cTokens.length;
        require(numMarkets != 0 && numMarkets == speeds.length && numMarkets == starts.length && numMarkets == ends.length, "invalid input");
        require(rewardTokensMap[rewardToken], "reward token was not added");

        for (uint i = 0; i < numMarkets; i++) {
            address cToken = cTokens[i];
            uint speed = speeds[i];
            uint start = starts[i];
            uint end = ends[i];
            if (supply) {
                RewardSpeed memory currentSpeed = rewardSupplySpeeds[rewardToken][cToken];
                if (currentSpeed.speed != 0) {
                    // Update the supply index.
                    updateGlobalSupplyIndex(rewardToken, cToken);
                } else if (speed != 0) {
                    // Initialize the supply index.
                    if (rewardSupplyState[rewardToken][cToken].index == 0 && rewardSupplyState[rewardToken][cToken].block == 0) {
                        rewardSupplyState[rewardToken][cToken] = RewardState({
                            index: initialIndex,
                            block: getBlockNumber()
                        });
                    }
                }

                if (currentSpeed.speed != speed) {
                    require(end > start, "the end block number must be greater than the start block number");
                    if (getBlockNumber() < currentSpeed.end && getBlockNumber() > currentSpeed.start && currentSpeed.start != 0) {
                        require(currentSpeed.start == start, "cannot change the start block number after the reward starts");
                    }
                    rewardSupplySpeeds[rewardToken][cToken] = RewardSpeed({
                        speed: speed,
                        start: start,
                        end: end
                    });
                    emit UpdateSupplyRewardSpeed(rewardToken, cToken, speed, start, end);
                }
            } else {
                RewardSpeed memory currentSpeed = rewardBorrowSpeeds[rewardToken][cToken];
                if (currentSpeed.speed != 0) {
                    // Update the borrow index.
                    uint marketBorrowIndex = CTokenInterface(cToken).borrowIndex();
                    updateGlobalBorrowIndex(rewardToken, cToken, marketBorrowIndex);
                } else if (speed != 0) {
                    // Initialize the borrow index.
                    if (rewardBorrowState[rewardToken][cToken].index == 0 && rewardBorrowState[rewardToken][cToken].block == 0) {
                        rewardBorrowState[rewardToken][cToken] = RewardState({
                            index: initialIndex,
                            block: getBlockNumber()
                        });
                    }
                }

                if (currentSpeed.speed != speed) {
                    require(end > start, "the end block number must be greater than the start block number");
                    if (getBlockNumber() < currentSpeed.end && getBlockNumber() > currentSpeed.start && currentSpeed.start != 0) {
                        require(currentSpeed.start == start, "cannot change the start block number after the reward starts");
                    }
                    rewardBorrowSpeeds[rewardToken][cToken] = RewardSpeed({
                        speed: speed,
                        start: start,
                        end: end
                    });
                    emit UpdateBorrowRewardSpeed(rewardToken, cToken, speed, start, end);
                }
            }
        }
    }

    /**
     * @dev Internal funciton to get the min value of two.
     * @param a The first value
     * @param b The second value
     * @return The min one
     */
    function min(uint a, uint b) internal pure returns (uint) {
        if (a < b) {
            return a;
        }
        return b;
    }

    /**
     * @dev Internal funciton to get the max value of two.
     * @param a The first value
     * @param b The second value
     * @return The max one
     */
    function max(uint a, uint b) internal pure returns (uint) {
        if (a > b) {
            return a;
        }
        return b;
    }
}
