# ConfidentialRebalancingHook - Deployment & Integration Guide

## 🚀 Quick Start

### Prerequisites

- Node.js 18+
- Foundry
- Fhenix FHE environment
- Uniswap v4 Pool Manager deployed
- Governance contract (for DAO strategies)

### Installation

```bash
# Clone the repository
git clone https://github.com/your-org/confidential-rebalancing-hook.git
cd confidential-rebalancing-hook

# Install dependencies
npm install

# Install Foundry
curl -L https://foundry.paradigm.xyz | bash
foundryup

# Compile contracts
forge build

# Run tests
forge test
```

## 📋 Deployment Guide

### 1. Configure Deployment Script

Edit `script/DeployConfidentialRebalancingHook.s.sol`:

```solidity
// Set your actual addresses
address constant POOL_MANAGER = address(0x1234...); // Your PoolManager address
address constant GOVERNANCE = address(0x5678...);   // Your governance contract
address[] constant AUTHORIZED_EXECUTORS = [
    address(0x9ABC...), // Trusted executor 1
    address(0xDEF0...)  // Trusted executor 2
];
```

### 2. Deploy to Testnet

```bash
# Deploy to Sepolia testnet
forge script script/DeployConfidentialRebalancingHook.s.sol:DeployConfidentialRebalancingHookTestnet \
    --rpc-url https://sepolia.infura.io/v3/YOUR_INFURA_KEY \
    --private-key $PRIVATE_KEY \
    --broadcast \
    --verify
```

### 3. Deploy to Mainnet

```bash
# Deploy to Ethereum mainnet
forge script script/DeployConfidentialRebalancingHook.s.sol:DeployConfidentialRebalancingHook \
    --rpc-url https://mainnet.infura.io/v3/YOUR_INFURA_KEY \
    --private-key $PRIVATE_KEY \
    --broadcast \
    --verify
```

### 4. Verify Deployment

```solidity
// Check hook permissions
Hooks.Permissions memory permissions = hook.getHookPermissions();
require(permissions.beforeSwap, "beforeSwap not enabled");
require(permissions.afterSwap, "afterSwap not enabled");

// Verify governance
require(hook.governance() == GOVERNANCE, "Governance not set");

// Check authorized executors
require(hook.authorizedExecutors(EXECUTOR_ADDRESS), "Executor not authorized");
```

## 🔧 Integration Guide

### 1. Basic Strategy Setup

```solidity
// Create encrypted execution parameters
InEuint128 memory executionWindow = CFT.createInEuint128(3600, user); // 1 hour
InEuint128 memory spreadBlocks = CFT.createInEuint128(100, user);       // 100 blocks
InEuint128 memory maxSlippage = CFT.createInEuint128(500, user);      // 5%

// Create strategy
bytes32 strategyId = keccak256("my-strategy");
bool success = hook.createStrategy(
    strategyId,
    100, // rebalance frequency
    executionWindow,
    spreadBlocks,
    maxSlippage
);
```

### 2. Set Target Allocations

```solidity
// Set 60% allocation for tokenA with 1% threshold
InEuint128 memory targetPercentage = CFT.createInEuint128(6000, user); // 60%
InEuint128 memory minThreshold = CFT.createInEuint128(100, user);      // 1%
InEuint128 memory maxThreshold = CFT.createInEuint128(1000, user);    // 10%

hook.setTargetAllocation(
    strategyId,
    tokenA,
    targetPercentage,
    minThreshold,
    maxThreshold
);
```

### 3. Update Encrypted Positions

```solidity
// Update encrypted position without revealing actual value
InEuint128 memory position = CFT.createInEuint128(1000000, user);
hook.setEncryptedPosition(strategyId, tokenA, position);
```

### 4. Enable Cross-Pool Coordination

```solidity
// Enable coordination across multiple pools
PoolId[] memory pools = new PoolId[](2);
pools[0] = poolId1;
pools[1] = poolId2;
hook.enableCrossPoolCoordination(strategyId, pools);
```

### 5. Execute Rebalancing

```solidity
// Calculate trade deltas
bool success = hook.calculateRebalancing(strategyId);

// Execute rebalancing (requires authorized executor)
hook.executeRebalancing(strategyId);
```

## 🏛️ DAO Integration

### 1. Create Governance Strategy

```solidity
// Create governance-controlled strategy
hook.createGovernanceStrategy(
    strategyId,
    rebalanceFrequency,
    executionWindow,
    spreadBlocks,
    maxSlippage
);
```

### 2. Enable Compliance Reporting

```solidity
// Enable compliance reporting for audit requirements
hook.enableComplianceReporting(strategyId, complianceOfficer);
```

### 3. Generate Compliance Reports

```solidity
// Generate audit trail for compliance
bool success = hook.generateComplianceReport(strategyId);
```

## 🔒 Security Considerations

### 1. Access Control

- **Strategy Ownership**: Only strategy owners can modify their strategies
- **Authorized Executors**: Controlled execution by trusted parties
- **Governance Voting**: Multi-signature approval for governance strategies

### 2. FHE Security

- **Encrypted Storage**: All sensitive data stored in encrypted form
- **Homomorphic Computation**: Operations performed on encrypted data
- **Threshold Decryption**: Multi-party decryption for security

### 3. Front-Running Protection

- **Encrypted Timing**: Execution timing hidden from MEV bots
- **Cross-Pool Coordination**: Strategy spread across multiple pools
- **Batch Execution**: Reduced visibility of individual trades

## 📊 Performance Optimization

### 1. Gas Optimization

- **Batch Operations**: Multiple operations in single transaction
- **Encrypted Constants**: Reuse encrypted values to reduce gas
- **Efficient Storage**: Optimized data structures for FHE operations

### 2. Scalability

- **Large Portfolios**: Supports institutional-scale rebalancing
- **Multi-Pool**: Cross-pool coordination without performance impact
- **Concurrent Execution**: Multiple strategies can run simultaneously

## 🧪 Testing

### 1. Run Test Suite

```bash
# Run all tests
forge test

# Run specific test contract
forge test --match-contract ConfidentialRebalancingHookTest

# Run integration tests
forge test --match-contract ConfidentialRebalancingHookIntegrationTest

# Run with gas reporting
forge test --gas-report
```

### 2. Test Coverage

```bash
# Generate coverage report
forge coverage
```

## 🔍 Monitoring & Maintenance

### 1. Event Monitoring

```solidity
// Monitor key events
event StrategyCreated(bytes32 indexed strategyId, address indexed owner);
event RebalancingExecuted(bytes32 indexed strategyId, uint256 blockNumber);
event ComplianceReportGenerated(bytes32 indexed strategyId, address indexed reporter);
```

### 2. Health Checks

```solidity
// Check system health
function checkSystemHealth() external view returns (bool) {
    // Verify hook permissions
    Hooks.Permissions memory permissions = getHookPermissions();
    require(permissions.beforeSwap && permissions.afterSwap, "Hook permissions invalid");

    // Verify governance
    require(governance != address(0), "Governance not set");

    return true;
}
```

### 3. Upgrade Management

```solidity
// Governance-controlled upgrades
function upgradeHook(address newImplementation) external onlyGovernance {
    // Upgrade logic
}
```

## 🚨 Troubleshooting

### Common Issues

1. **Hook Address Mismatch**

   - Ensure CREATE2 deployment with correct permissions
   - Verify salt calculation matches HookMiner

2. **FHE Operation Failures**

   - Check FHE library compatibility
   - Verify encrypted data access permissions

3. **Gas Limit Exceeded**

   - Optimize batch operations
   - Reduce encrypted computation complexity

4. **Access Control Issues**
   - Verify strategy ownership
   - Check authorized executor permissions

### Debug Commands

```bash
# Debug specific test
forge test --match-test testCreateStrategy -vvvv

# Trace transaction
forge test --match-test testExecuteRebalancing --debug

# Gas profiling
forge test --gas-report --match-contract ConfidentialRebalancingHookTest
```

## 📞 Support

- **Documentation**: [Full Documentation](https://docs.confidential-rebalancing.com)
- **Issues**: [GitHub Issues](https://github.com/your-org/confidential-rebalancing-hook/issues)
- **Discord**: [Community Discord](https://discord.gg/confidential-rebalancing)
- **Email**: support@confidential-rebalancing.com

## 📄 License

MIT License - see LICENSE file for details.

---

**Built with ❤️ for the future of confidential DeFi**

_Revolutionizing institutional trading with zero-knowledge rebalancing on Uniswap v4_ 🚀
