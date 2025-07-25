/** yield Farming Aggregator **/
//
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

/**
 * @title YieldFarmingAggregator
 * @dev A decentralized yield farming aggregator that optimizes returns across multiple pools
 */
contract YieldFarmingAggregator is Ownable, ReentrancyGuard, Pausable {
    struct Pool {
        address stakingToken;
        address rewardToken;
        uint256 totalStaked;
        uint256 rewardRate;
        uint256 lastUpdateTime;
        uint256 rewardPerTokenStored;
        uint256 poolCapacity;
        bool isActive;
    }

    struct UserInfo {
        uint256 stakedAmount;
        uint256 rewardDebt;
        uint256 pendingRewards;
        uint256 lastStakeTime;
        uint256 totalRewardsEarned;
    }

    struct Strategy {
        uint256[] poolIds;
        uint256[] allocations;
        uint256 totalAllocation;
        bool isActive;
    }

    mapping(uint256 => Pool) public pools;
    mapping(uint256 => mapping(address => UserInfo)) public userInfo;
    mapping(uint256 => Strategy) public strategies;
    mapping(address => bool) public authorizedTokens;

    uint256 public poolCount;
    uint256 public strategyCount;
    uint256 public constant PRECISION = 1e18;
    uint256 public constant BASIS_POINTS = 10000;
    uint256 public constant MIN_STAKE_AMOUNT = 1e15;
    uint256 public totalValueLocked;

    event PoolCreated(uint256 indexed poolId, address stakingToken, address rewardToken, uint256 rewardRate);
    event TokensStaked(address indexed user, uint256 indexed poolId, uint256 amount);
    event TokensWithdrawn(address indexed user, uint256 indexed poolId, uint256 amount);
    event RewardsClaimed(address indexed user, uint256 indexed poolId, uint256 amount);
    event StrategyExecuted(address indexed user, uint256 indexed strategyId, uint256 totalAmount);
    event PoolUpdated(uint256 indexed poolId, uint256 newRewardRate);
    event EmergencyWithdrawal(address indexed user, uint256 indexed poolId, uint256 amount);

    constructor() Ownable(msg.sender) {}

    function stakeTokens(uint256 poolId, uint256 amount) external nonReentrant whenNotPaused {
        require(poolId < poolCount, "Invalid pool ID");
        require(amount >= MIN_STAKE_AMOUNT, "Amount below minimum");

        Pool storage pool = pools[poolId];
        require(pool.isActive, "Pool is inactive");
        require(pool.totalStaked + amount <= pool.poolCapacity, "Pool capacity exceeded");
        require(authorizedTokens[pool.stakingToken], "Token not authorized");

        UserInfo storage user = userInfo[poolId][msg.sender];

        _updatePool(poolId);
        _harvestRewards(poolId, msg.sender);

        IERC20(pool.stakingToken).transferFrom(msg.sender, address(this), amount);

        user.stakedAmount += amount;
        user.lastStakeTime = block.timestamp;
        user.rewardDebt = (user.stakedAmount * pool.rewardPerTokenStored) / PRECISION;

        pool.totalStaked += amount;
        totalValueLocked += amount;

        emit TokensStaked(msg.sender, poolId, amount);
    }

    function executeStrategy(uint256 strategyId, uint256 totalAmount) external nonReentrant whenNotPaused {
        require(strategyId < strategyCount, "Invalid strategy ID");
        require(totalAmount >= MIN_STAKE_AMOUNT, "Amount below minimum");

        Strategy storage strategy = strategies[strategyId];
        require(strategy.isActive, "Strategy is inactive");
        require(strategy.totalAllocation == BASIS_POINTS, "Invalid allocation");

        for (uint256 i = 0; i < strategy.poolIds.length; i++) {
            uint256 poolId = strategy.poolIds[i];
            uint256 allocation = strategy.allocations[i];
            uint256 stakeAmount = (totalAmount * allocation) / BASIS_POINTS;

            if (stakeAmount > 0) {
                _stakeInPool(poolId, stakeAmount, msg.sender);
            }
        }

        emit StrategyExecuted(msg.sender, strategyId, totalAmount);
    }

    function withdrawAndClaim(uint256 poolId, uint256 amount) external nonReentrant {
        require(poolId < poolCount, "Invalid pool ID");

        UserInfo storage user = userInfo[poolId][msg.sender];
        require(user.stakedAmount > 0, "No tokens staked");

        if (amount == 0) {
            amount = user.stakedAmount;
        }

        require(amount <= user.stakedAmount, "Insufficient staked amount");

        Pool storage pool = pools[poolId];

        _updatePool(poolId);
        uint256 rewards = _harvestRewards(poolId, msg.sender);

        user.stakedAmount -= amount;
        user.rewardDebt = (user.stakedAmount * pool.rewardPerTokenStored) / PRECISION;

        pool.totalStaked -= amount;
        totalValueLocked -= amount;

        IERC20(pool.stakingToken).transfer(msg.sender, amount);

        emit TokensWithdrawn(msg.sender, poolId, amount);

        if (rewards > 0) {
            emit RewardsClaimed(msg.sender, poolId, rewards);
        }
    }

    function restakeRewards(uint256 poolId) external nonReentrant whenNotPaused {
        require(poolId < poolCount, "Invalid pool ID");

        Pool storage pool = pools[poolId];
        require(pool.stakingToken == pool.rewardToken, "Restake not supported for this pool");

        _updatePool(poolId);
        uint256 rewards = _harvestRewards(poolId, msg.sender);
        require(rewards >= MIN_STAKE_AMOUNT, "Insufficient rewards to restake");

        UserInfo storage user = userInfo[poolId][msg.sender];

        user.stakedAmount += rewards;
        user.rewardDebt = (user.stakedAmount * pool.rewardPerTokenStored) / PRECISION;
        user.lastStakeTime = block.timestamp;

        pool.totalStaked += rewards;
        totalValueLocked += rewards;

        emit TokensStaked(msg.sender, poolId, rewards);
    }

    function _updatePool(uint256 poolId) internal {
        Pool storage pool = pools[poolId];

        if (block.timestamp <= pool.lastUpdateTime || pool.totalStaked == 0) {
            pool.lastUpdateTime = block.timestamp;
            return;
        }

        uint256 timeElapsed = block.timestamp - pool.lastUpdateTime;
        uint256 rewards = timeElapsed * pool.rewardRate;

        pool.rewardPerTokenStored += (rewards * PRECISION) / pool.totalStaked;
        pool.lastUpdateTime = block.timestamp;
    }

    function _harvestRewards(uint256 poolId, address userAddress) internal returns (uint256) {
        Pool storage pool = pools[poolId];
        UserInfo storage user = userInfo[poolId][userAddress];

        if (user.stakedAmount == 0) {
            return 0;
        }

        uint256 pending = ((user.stakedAmount * pool.rewardPerTokenStored) / PRECISION) - user.rewardDebt;
        uint256 totalRewards = user.pendingRewards + pending;

        if (totalRewards > 0) {
            user.pendingRewards = 0;
            user.totalRewardsEarned += totalRewards;
            IERC20(pool.rewardToken).transfer(userAddress, totalRewards);
        }

        return totalRewards;
    }

    function _stakeInPool(uint256 poolId, uint256 amount, address user) internal {
        Pool storage pool = pools[poolId];
        require(pool.isActive, "Pool is inactive");
        require(pool.totalStaked + amount <= pool.poolCapacity, "Pool capacity exceeded");

        UserInfo storage userStake = userInfo[poolId][user];

        _updatePool(poolId);
        _harvestRewards(poolId, user);

        userStake.stakedAmount += amount;
        userStake.lastStakeTime = block.timestamp;
        userStake.rewardDebt = (userStake.stakedAmount * pool.rewardPerTokenStored) / PRECISION;

        pool.totalStaked += amount;
        totalValueLocked += amount;

        emit TokensStaked(user, poolId, amount);
    }

    function createPool(address stakingToken, address rewardToken, uint256 rewardRate, uint256 poolCapacity) external onlyOwner {
        require(stakingToken != address(0) && rewardToken != address(0), "Invalid token addresses");
        require(rewardRate > 0, "Invalid reward rate");
        require(poolCapacity > 0, "Invalid pool capacity");

        pools[poolCount] = Pool({
            stakingToken: stakingToken,
            rewardToken: rewardToken,
            totalStaked: 0,
            rewardRate: rewardRate,
            lastUpdateTime: block.timestamp,
            rewardPerTokenStored: 0,
            poolCapacity: poolCapacity,
            isActive: true
        });

        authorizedTokens[stakingToken] = true;

        emit PoolCreated(poolCount, stakingToken, rewardToken, rewardRate);
        poolCount++;
    }

    function createStrategy(uint256[] calldata poolIds, uint256[] calldata allocations) external onlyOwner {
        require(poolIds.length == allocations.length, "Array length mismatch");
        require(poolIds.length > 0, "Empty strategy");

        uint256 totalAllocation = 0;
        for (uint256 i = 0; i < allocations.length; i++) {
            require(poolIds[i] < poolCount, "Invalid pool ID");
            totalAllocation += allocations[i];
        }

        require(totalAllocation == BASIS_POINTS, "Invalid total allocation");

        strategies[strategyCount] = Strategy({
            poolIds: poolIds,
            allocations: allocations,
            totalAllocation: totalAllocation,
            isActive: true
        });

        strategyCount++;
    }

    function updatePoolRewardRate(uint256 poolId, uint256 newRate) external onlyOwner {
        require(poolId < poolCount, "Invalid pool ID");
        _updatePool(poolId);
        pools[poolId].rewardRate = newRate;
        emit PoolUpdated(poolId, newRate);
    }

    function togglePool(uint256 poolId) external onlyOwner {
        require(poolId < poolCount, "Invalid pool ID");
        pools[poolId].isActive = !pools[poolId].isActive;
    }

    function toggleStrategy(uint256 strategyId) external onlyOwner {
        require(strategyId < strategyCount, "Invalid strategy ID");
        strategies[strategyId].isActive = !strategies[strategyId].isActive;
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    function emergencyWithdraw(uint256 poolId) external nonReentrant {
        require(poolId < poolCount, "Invalid pool ID");

        UserInfo storage user = userInfo[poolId][msg.sender];
        require(user.stakedAmount > 0, "No tokens staked");

        Pool storage pool = pools[poolId];
        uint256 amount = user.stakedAmount;

        user.stakedAmount = 0;
        user.rewardDebt = 0;
        user.pendingRewards = 0;

        pool.totalStaked -= amount;
        totalValueLocked -= amount;

        IERC20(pool.stakingToken).transfer(msg.sender, amount);

        emit EmergencyWithdrawal(msg.sender, poolId, amount);
    }

    function getPendingRewards(uint256 poolId, address userAddress) external view returns (uint256) {
        Pool storage pool = pools[poolId];
        UserInfo storage user = userInfo[poolId][userAddress];

        if (user.stakedAmount == 0) {
            return user.pendingRewards;
        }

        uint256 rewardPerToken = pool.rewardPerTokenStored;
        if (pool.totalStaked > 0) {
            uint256 timeElapsed = block.timestamp - pool.lastUpdateTime;
            uint256 rewards = timeElapsed * pool.rewardRate;
            rewardPerToken += (rewards * PRECISION) / pool.totalStaked;
        }

        uint256 pending = ((user.stakedAmount * rewardPerToken) / PRECISION) - user.rewardDebt;
        return user.pendingRewards + pending;
    }

    function getPoolInfo(uint256 poolId) external view returns (address, address, uint256, uint256, uint256, bool) {
        Pool storage pool = pools[poolId];
        return (
            pool.stakingToken,
            pool.rewardToken,
            pool.totalStaked,
            pool.rewardRate,
            pool.poolCapacity,
            pool.isActive
        );
    }

    function getUserInfo(uint256 poolId, address userAddress) external view returns (uint256, uint256, uint256, uint256) {
        UserInfo storage user = userInfo[poolId][userAddress];
        uint256 pending = this.getPendingRewards(poolId, userAddress);

        return (
            user.stakedAmount,
            pending,
            user.totalRewardsEarned,
            user.lastStakeTime
        );
    }

    function getStrategyInfo(uint256 strategyId) external view returns (uint256[] memory, uint256[] memory, bool) {
        Strategy storage strategy = strategies[strategyId];
        return (strategy.poolIds, strategy.allocations, strategy.isActive);
    }
}

