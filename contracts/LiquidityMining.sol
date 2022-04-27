// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "./LiquidityMiningStorage.sol";
import "./interfaces/ComptrollerInterface.sol";
import "./interfaces/CTokenInterface.sol";
import "./interfaces/LiquidityMiningInterface.sol";

contract LiquidityMining is Initializable, UUPSUpgradeable, OwnableUpgradeable, LiquidityMiningStorage, LiquidityMiningInterface {
    using SafeERC20 for IERC20;

    uint internal constant initialIndex = 1e18;

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
    event UpdateBorrowerRewardIndex(
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
        address indexed receiver,
        uint amount
    );

    /**
     * @notice Emitted when a debtor is updated
     */
    event UpdateDebtor(
        address indexed account,
        bool indexed isDebtor
    );

    /**
     * @notice Emitted when a reward receiver is updated
     */
    event UpdateRewardReceiver(
        address indexed account,
        address indexed receiver
    );

    struct UserMarkets {
        address market;
        bool supply;
        bool borrow;
    }

    struct RewardTokenInfo {
        address rewardTokenAddress;
        string rewardTokenSymbol;
        uint8 rewardTokenDecimals;
    }

    struct RewardAvailable {
        RewardTokenInfo rewardToken;
        uint amount;
    }

    struct RewardSpeedInfo {
        RewardTokenInfo rewardToken;
        RewardSpeed supplySpeed;
        RewardSpeed borrowSpeed;
    }

    struct MarketRewardSpeed {
        address cToken;
        RewardSpeedInfo[] rewardSpeeds;
    }

    /**
     * @notice Initialize the contract with admin and comptroller
     */
    function initialize(address _admin, address _comptroller) initializer public {
        __Ownable_init();

        comptroller = _comptroller;
        transferOwnership(_admin);
    }

    /* ========== VIEW FUNCTIONS ========== */

    /**
     * @notice Return the current block timestamp.
     * @return The current block timestamp
     */
    function getBlockTimestamp() public virtual view returns (uint) {
        return block.timestamp;
    }

    /**
     * @notice Return the reward token list.
     * @return The list of reward token addresses
     */
    function getRewardTokenList() external view returns (address[] memory) {
        return rewardTokens;
    }

    /**
     * @notice Get reward token info.
     * @param rewardToken The reward token address
     * @return The reward token info
     */
    function getRewardTokenInfo(address rewardToken) public view returns (RewardTokenInfo memory) {
        return RewardTokenInfo({
            rewardTokenAddress: rewardToken,
            rewardTokenSymbol: IERC20Metadata(rewardToken).symbol(),
            rewardTokenDecimals: IERC20Metadata(rewardToken).decimals()
        });
    }

    /**
     * @notice Get reward speed info by market.
     * @param cToken The market address
     * @return The market reward speed info
     */
    function getMarketRewardSpeeds(address cToken) public view returns (MarketRewardSpeed memory) {
        RewardSpeedInfo[] memory rewardSpeeds = new RewardSpeedInfo[](rewardTokens.length);
        for (uint i = 0; i < rewardTokens.length; i++) {
            rewardSpeeds[i] = RewardSpeedInfo({
                rewardToken: getRewardTokenInfo(rewardTokens[i]),
                supplySpeed: rewardSupplySpeeds[rewardTokens[i]][cToken],
                borrowSpeed: rewardBorrowSpeeds[rewardTokens[i]][cToken]
            });
        }
        return MarketRewardSpeed({
            cToken: cToken,
            rewardSpeeds: rewardSpeeds
        });
    }

    /**
     * @notice Get all market reward speed info.
     * @param cTokens The market addresses
     * @return The list of reward speed info
     */
    function getMultipleMarketRewardSpeeds(address[] memory cTokens) public view returns (MarketRewardSpeed[] memory) {
        MarketRewardSpeed[] memory allRewardSpeeds = new MarketRewardSpeed[](cTokens.length);
        for (uint i = 0; i < cTokens.length; i++) {
            allRewardSpeeds[i] = getMarketRewardSpeeds(cTokens[i]);
        }
        return allRewardSpeeds;
    }

    /* ========== MUTATIVE FUNCTIONS ========== */

    /**
     * @notice Check if the msg.sender is the account or the account delegate rewards receiver.
     * @param account The account address
     */
    modifier onlyAccount(address account) {
        if (rewardReceivers[account] != address(0)) {
            require(msg.sender == rewardReceivers[account], "unauthorized");
        } else {
            require(msg.sender == account, "unauthorized");
        }
        _;
    }

    /**
     * @notice Accrue rewards to the market by updating the supply index and calculate rewards accrued by suppliers
     * @param cToken The market whose supply index to update
     * @param suppliers The related suppliers
     */
    function updateSupplyIndex(address cToken, address[] memory suppliers) external override {
        // Distribute the rewards right away.
        updateSupplyIndexInternal(rewardTokens, cToken, suppliers, true);
    }

    /**
     * @notice Accrue rewards to the market by updating the borrow index and calculate rewards accrued by borrowers
     * @param cToken The market whose borrow index to update
     * @param borrowers The related borrowers
     */
    function updateBorrowIndex(address cToken, address[] memory borrowers) external override {
        // Distribute the rewards right away.
        updateBorrowIndexInternal(rewardTokens, cToken, borrowers, true);
    }

    /**
     * @notice Claim all the rewards accrued by holder in all markets
     * @param account The account address
     */
    function claimAllRewards(address account) public onlyAccount(account) {
        address[] memory allMarkets = ComptrollerInterface(comptroller).getAllMarkets();
        return claimRewards(account, allMarkets, rewardTokens, true, true);
    }

    /**
     * @notice Claim the rewards accrued by the account
     * @param account The account address
     * @param cTokens The list of markets to claim rewards in
     * @param rewards The list of reward tokens to claim
     * @param borrowers Whether or not to claim rewards earned by borrowing
     * @param suppliers Whether or not to claim rewards earned by supplying
     */
    function claimRewards(address account, address[] memory cTokens, address[] memory rewards, bool borrowers, bool suppliers) public onlyAccount(account) {
        require(!debtors[account], "debtor is not allowed to claim rewards");
        for (uint i = 0; i < cTokens.length; i++) {
            address cToken = cTokens[i];

            address[] memory accounts = new address[](1);
            accounts[0] = account;

            // Same reward generated from multiple markets could aggregate and distribute once later for gas consumption.
            if (borrowers) {
                updateBorrowIndexInternal(rewards, cToken, accounts, false);
            }
            if (suppliers) {
                updateSupplyIndexInternal(rewards, cToken, accounts, false);
            }
        }

        // Distribute the rewards.
        for (uint i = 0; i < rewards.length; i++) {
            rewardAccrued[rewards[i]][account] = transferReward(rewards[i], account, rewardAccrued[rewards[i]][account]);
        }
    }

    /**
     * @notice Claim the rewards accrued by one account and a specifc reward token
     * @dev This function is not efficient for claiming user rewards but it's useful to get the user related markets by using a staticcall.
     * @param account The account address
     * @param reward The reward token address
     * @return The list of user related markets
     */
    function claimSingleReward(address account, address reward) public onlyAccount(account) returns (UserMarkets[] memory) {
        require(rewardTokensMap[reward], "reward token not support");
        require(!debtors[account], "debtor is not allowed to claim rewards");

        address[] memory allMarkets = ComptrollerInterface(comptroller).getAllMarkets();
        UserMarkets[] memory userMarkets = new UserMarkets[](allMarkets.length);
        for (uint i = 0; i < allMarkets.length; i++) {
            uint marketBorrowIndex = CTokenInterface(allMarkets[i]).borrowIndex();
            updateGlobalBorrowIndex(reward, allMarkets[i], marketBorrowIndex);
            bool affectBorrow = updateUserBorrowIndex(reward, allMarkets[i], account, marketBorrowIndex, true);

            updateGlobalSupplyIndex(reward, allMarkets[i]);
            bool affectSupply = updateUserSupplyIndex(reward, allMarkets[i], account, true);

            userMarkets[i] = UserMarkets({
                market: allMarkets[i],
                supply: affectSupply,
                borrow: affectBorrow
            });
        }
        return userMarkets;
    }

    /**
     * @notice Get user all available rewards.
     * @dev This function is normally used by staticcall.
     * @param account The user address
     * @return The list of user available rewards
     */
    function getRewardsAvailable(address account) public onlyAccount(account) returns (RewardAvailable[] memory) {
        uint[] memory beforeBalances = new uint[](rewardTokens.length);
        RewardAvailable[] memory rewardAvailables = new RewardAvailable[](rewardTokens.length);

        for (uint i = 0; i < rewardTokens.length; i++) {
            beforeBalances[i] = IERC20(rewardTokens[i]).balanceOf(account);
        }

        claimAllRewards(account);

        for (uint i = 0; i < rewardTokens.length; i++) {
            uint newBalance = IERC20(rewardTokens[i]).balanceOf(account);
            rewardAvailables[i] = RewardAvailable({
                rewardToken: getRewardTokenInfo(rewardTokens[i]),
                amount: newBalance - beforeBalances[i]
            });
        }
        return rewardAvailables;
    }

    /* ========== ADMIN FUNCTIONS ========== */

    /**
     * @notice Update accounts to be debtors or not. Debtors couldn't claim rewards until their bad debts are repaid.
     * @param accounts The list of accounts to be updated
     */
    function updateDebtors(address[] memory accounts) external onlyOwner {
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

    /**
     * @notice Set the reward delegate receiver for an account
     * @param account The account address
     * @param receiver The receiver address
     */
    function setRewardsReceiver(address account, address receiver) external onlyOwner {
        rewardReceivers[account] = receiver;

        emit UpdateRewardReceiver(account, receiver);
    }

    /**
     * @notice Add new reward token. Revert if the reward token has been added
     * @param rewardToken The new reward token
     */
    function addRewardToken(address rewardToken) external onlyOwner {
        require(!rewardTokensMap[rewardToken], "reward token has been added");
        rewardTokensMap[rewardToken] = true;
        rewardTokens.push(rewardToken);
    }

    /**
     * @notice Set cTokens reward supply speeds
     * @param rewardToken The reward token
     * @param cTokens The addresses of cTokens
     * @param speeds The list of reward speeds
     * @param starts The list of start timestamps
     * @param ends The list of end timestamps
     */
    function setRewardSupplySpeeds(address rewardToken, address[] memory cTokens, uint[] memory speeds, uint[] memory starts, uint[] memory ends) external onlyOwner {
        _setRewardSpeeds(rewardToken, cTokens, speeds, starts, ends, true);
    }

    /**
     * @notice Set cTokens reward borrow speeds
     * @param rewardToken The reward token
     * @param cTokens The addresses of cTokens
     * @param speeds The list of reward speeds
     * @param starts The list of start timestamps
     * @param ends The list of end timestamps
     */
    function setRewardBorrowSpeeds(address rewardToken, address[] memory cTokens, uint[] memory speeds, uint[] memory starts, uint[] memory ends) external onlyOwner {
        _setRewardSpeeds(rewardToken, cTokens, speeds, starts, ends, false);
    }

    /* ========== INTERNAL FUNCTIONS ========== */

    /**
     * @dev _authorizeUpgrade is used by UUPSUpgradeable to determine if it's allowed to upgrade a proxy implementation.
     * @param newImplementation The new implementation
     *
     * Ref: https://github.com/OpenZeppelin/openzeppelin-contracts/blob/master/contracts/proxy/utils/UUPSUpgradeable.sol
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

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
        uint timestamp = getBlockTimestamp();
        if (timestamp > supplyState.timestamp) {
            if (supplySpeed.speed == 0 || supplySpeed.start > timestamp || supplyState.timestamp > supplySpeed.end) {
                // 1. The reward speed is zero,
                // 2. The reward hasn't started yet,
                // 3. The supply state has handled the end of the reward,
                // just update the timestamp.
                supplyState.timestamp = timestamp;
            } else {
                // fromTimestamp is the max of the last update block timestamp and the reward start block timestamp.
                uint fromTimestamp = max(supplyState.timestamp, supplySpeed.start);
                // toTimestamp is the min of the current block timestamp and the reward end block timestamp.
                uint toTimestamp = min(timestamp, supplySpeed.end);
                // deltaTime is the time difference used for calculating the rewards.
                uint deltaTime = toTimestamp - fromTimestamp;
                uint rewardAccrued = deltaTime * supplySpeed.speed;
                uint totalSupply = CTokenInterface(cToken).totalSupply();
                uint ratio = totalSupply > 0 ? rewardAccrued * 1e18 / totalSupply : 0;
                uint index = supplyState.index + ratio;
                rewardSupplyState[rewardToken][cToken] = RewardState({
                    index: index,
                    timestamp: timestamp
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
        uint timestamp = getBlockTimestamp();
        if (timestamp > borrowState.timestamp) {
            if (borrowSpeed.speed == 0 || timestamp < borrowSpeed.start || borrowState.timestamp > borrowSpeed.end) {
                // 1. The reward speed is zero,
                // 2. The reward hasn't started yet,
                // 3. The borrow state has handled the end of the reward,
                // just update the timestamp.
                borrowState.timestamp = timestamp;
            } else {
                // fromTimestamp is the max of the last update block timestamp and the reward start block timestamp.
                uint fromTimestamp = max(borrowState.timestamp, borrowSpeed.start);
                // toTimestamp is the min of the current block timestamp and the reward end block timestamp.
                uint toTimestamp = min(timestamp, borrowSpeed.end);
                // deltaTime is the time difference used for calculating the rewards.
                uint deltaTime = toTimestamp - fromTimestamp;
                uint rewardAccrued = deltaTime * borrowSpeed.speed;
                uint totalBorrows = CTokenInterface(cToken).totalBorrows() * 1e18 / marketBorrowIndex;
                uint ratio = totalBorrows > 0 ? rewardAccrued * 1e18 / totalBorrows : 0;
                uint index = borrowState.index + ratio;
                rewardBorrowState[rewardToken][cToken] = RewardState({
                    index: index,
                    timestamp: timestamp
                });
            }
        }
    }

    /**
     * @notice Calculate rewards accrued by a supplier and possibly transfer it to them
     * @dev Suppliers will not begin to accrue until after the first interaction with the protocol.
     * @param rewardToken The reward token
     * @param cToken The market in which the supplier is interacting
     * @param supplier The address of the supplier to distribute rewards to
     * @param distribute Distribute the reward or not
     * @return If the market will increase the user supply rewards after this update or not
     */
    function updateUserSupplyIndex(address rewardToken, address cToken, address supplier, bool distribute) internal returns (bool) {
        RewardState memory supplyState = rewardSupplyState[rewardToken][cToken];
        uint supplyIndex = supplyState.index;
        uint supplierIndex = rewardSupplierIndex[rewardToken][cToken][supplier];
        rewardSupplierIndex[rewardToken][cToken][supplier] = supplyIndex;

        if (supplierIndex == 0 && supplyIndex > 0) {
            supplierIndex = initialIndex;
        }

        if (supplierIndex > 0) {
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
            return supplierDelta > 0;
        }
        return false;
    }

    /**
     * @notice Calculate rewards accrued by a borrower and possibly transfer it to them
     * @dev Borrowers will not begin to accrue until after the first interaction with the protocol.
     * @param rewardToken The reward token
     * @param cToken The market in which the borrower is interacting
     * @param borrower The address of the borrower to distribute rewards to
     * @param marketBorrowIndex The market borrow index
     * @param distribute Distribute the reward or not
     * @return If the market will increase the user borrow rewards after this update or not
     */
    function updateUserBorrowIndex(address rewardToken, address cToken, address borrower, uint marketBorrowIndex, bool distribute) internal returns (bool) {
        RewardState memory borrowState = rewardBorrowState[rewardToken][cToken];
        uint borrowIndex = borrowState.index;
        uint borrowerIndex = rewardBorrowerIndex[rewardToken][cToken][borrower];
        rewardBorrowerIndex[rewardToken][cToken][borrower] = borrowIndex;

        if (borrowerIndex == 0 && borrowIndex > 0) {
            borrowerIndex = initialIndex;
        }

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
            emit UpdateBorrowerRewardIndex(rewardToken, cToken, borrower, borrowerDelta, borrowIndex);
            return borrowerDelta > 0;
        }
        return false;
    }

    /**
     * @notice Transfer rewards to the user
     * @param rewardToken The reward token
     * @param user The address of the user to transfer rewards to
     * @param amount The amount of rewards to (possibly) transfer
     * @return The amount of rewards which was NOT transferred to the user
     */
    function transferReward(address rewardToken, address user, uint amount) internal returns (uint) {
        uint remain = IERC20(rewardToken).balanceOf(address(this));
        if (amount > 0 && amount <= remain && !debtors[user]) {
            address receiver = rewardReceivers[user];
            if (receiver == address(0)) {
                // Rewards delegate receiver not set, send rewards to the actual user.
                receiver = user;
            }

            IERC20(rewardToken).safeTransfer(receiver, amount);
            emit TransferReward(rewardToken, user, receiver, amount);
            return 0;
        }
        return amount;
    }

    /**
     * @notice Set reward speeds
     * @param rewardToken The reward token
     * @param cTokens The addresses of cTokens
     * @param speeds The list of reward speeds
     * @param starts The list of start timestamps
     * @param ends The list of end timestamp
     * @param supply It's supply speed or borrow speed
     */
    function _setRewardSpeeds(address rewardToken, address[] memory cTokens, uint[] memory speeds, uint[] memory starts, uint[] memory ends, bool supply) internal {
        uint timestamp = getBlockTimestamp();
        uint numMarkets = cTokens.length;
        require(numMarkets != 0 && numMarkets == speeds.length && numMarkets == starts.length && numMarkets == ends.length, "invalid input");
        require(rewardTokensMap[rewardToken], "reward token was not added");

        for (uint i = 0; i < numMarkets; i++) {
            address cToken = cTokens[i];
            uint speed = speeds[i];
            uint start = starts[i];
            uint end = ends[i];
            if (supply) {
                if (isSupplyRewardStateInit(rewardToken, cToken)) {
                    // Update the supply index.
                    updateGlobalSupplyIndex(rewardToken, cToken);
                } else {
                    // Initialize the supply index.
                    rewardSupplyState[rewardToken][cToken] = RewardState({
                        index: initialIndex,
                        timestamp: timestamp
                    });
                }

                validateRewardContent(rewardSupplySpeeds[rewardToken][cToken], start, end);
                rewardSupplySpeeds[rewardToken][cToken] = RewardSpeed({
                    speed: speed,
                    start: start,
                    end: end
                });
                emit UpdateSupplyRewardSpeed(rewardToken, cToken, speed, start, end);
            } else {
                if (isBorrowRewardStateInit(rewardToken, cToken)) {
                    // Update the borrow index.
                    uint marketBorrowIndex = CTokenInterface(cToken).borrowIndex();
                    updateGlobalBorrowIndex(rewardToken, cToken, marketBorrowIndex);
                } else {
                    // Initialize the borrow index.
                    rewardBorrowState[rewardToken][cToken] = RewardState({
                        index: initialIndex,
                        timestamp: timestamp
                    });
                }

                validateRewardContent(rewardBorrowSpeeds[rewardToken][cToken], start, end);
                rewardBorrowSpeeds[rewardToken][cToken] = RewardSpeed({
                    speed: speed,
                    start: start,
                    end: end
                });
                emit UpdateBorrowRewardSpeed(rewardToken, cToken, speed, start, end);
            }
        }
    }

    /**
     * @notice Internal function to tell if the supply reward state is initialized or not.
     * @param rewardToken The reward token
     * @param cToken The market
     * @return It's initialized or not
     */
    function isSupplyRewardStateInit(address rewardToken, address cToken) internal view returns (bool) {
        return rewardSupplyState[rewardToken][cToken].index != 0 && rewardSupplyState[rewardToken][cToken].timestamp != 0;
    }

    /**
     * @notice Internal function to tell if the borrow reward state is initialized or not.
     * @param rewardToken The reward token
     * @param cToken The market
     * @return It's initialized or not
     */
    function isBorrowRewardStateInit(address rewardToken, address cToken) internal view returns (bool) {
        return rewardBorrowState[rewardToken][cToken].index != 0 && rewardBorrowState[rewardToken][cToken].timestamp != 0;
    }

    /**
     * @notice Internal function to check the new start block timestamp and the end block timestamp.
     * @dev This function will revert if any validation failed.
     * @param currentSpeed The current reward speed
     * @param newStart The new start timestamp
     * @param newEnd The new end block timestamp
     */
    function validateRewardContent(RewardSpeed memory currentSpeed, uint newStart, uint newEnd) internal view {
        uint timestamp = getBlockTimestamp();
        require(newEnd >= timestamp, "the end timestamp must be greater than the current timestamp");
        require(newEnd >= newStart, "the end timestamp must be greater than the start timestamp");
        if (timestamp < currentSpeed.end && timestamp > currentSpeed.start && currentSpeed.start != 0) {
            require(currentSpeed.start == newStart, "cannot change the start timestamp after the reward starts");
        }
    }

    /**
     * @notice Internal function to get the min value of two.
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
     * @notice Internal function to get the max value of two.
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
