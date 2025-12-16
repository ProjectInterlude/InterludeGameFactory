const { ethers } = require('ethers');
const solc = require('solc');
const fs = require('fs');
const path = require('path');
require('dotenv').config();

// Solidity compiler wrapper to handle version loading
class SolidityCompiler {
    constructor() {
        this.compiler = solc;
        this.targetVersion = null;
    }
    
    async loadVersion(version) {
        if (version && version !== 'default') {
            console.log(`🔧 Loading Solidity compiler version ${version}...`);
            try {
                // Load specific compiler version
                const solcVersion = require('solc/wrapper');
                const solcSnapshot = await new Promise((resolve, reject) => {
                    solc.loadRemoteVersion(version, (err, solcSnapshot) => {
                        if (err) reject(err);
                        else resolve(solcSnapshot);
                    });
                });
                this.compiler = solcSnapshot;
                this.targetVersion = version;
                console.log(`✅ Loaded Solidity compiler version ${version}`);
            } catch (error) {
                console.warn(`⚠️  Failed to load compiler version ${version}, using default: ${error.message}`);
                this.compiler = solc;
            }
        }
        return this.compiler;
    }
    
    version() {
        return this.compiler.version();
    }
    
    compile(input, options) {
        return this.compiler.compile(input, options);
    }
}

/**
 * Complete Onchain Game System Deployment Script
 * 
 * Deploys the optimized three-contract architecture:
 * 1. OnchainGameManager - Game registry and configuration
 * 2. OnchainGameEarnings - Financial handling with fee structure
 * 3. OnchainGameLeaderboard - Rankings and weighted jackpot system
 * 
 * Plus supporting contracts:
 * - TokenWhitelist (optional)
 * - ScratchCardGame (example game implementation)
 * - TestToken (for testing)
 */

class CompleteOnchainGameDeployer {
    constructor(chain = null, solidityVersion = null) {
        this.provider = null;
        this.signer = null;
        this.contracts = {};
        this.chain = chain || process.env.CHAIN || 'localhost';
        this.network = this.chain; // Keep backward compatibility
        this.deployedAddresses = {};
        this.contractArtifacts = {};
        this.nonce = null; // Manual nonce tracking
        this.chainConfig = {};
        this.solidityCompiler = new SolidityCompiler();
        this.targetSolidityVersion = solidityVersion || process.env.SOLIDITY_VERSION || null;
    }

    async initialize() {
        console.log('🚀 Initializing Complete Onchain Game Deployment...');
        console.log(`📡 Target Chain: ${this.chain}`);
        
        // Load specific Solidity compiler version if specified
        if (this.targetSolidityVersion) {
            await this.solidityCompiler.loadVersion(this.targetSolidityVersion);
        }
        
        // Load chain-specific configuration
        await this.loadChainConfig();
        
        // Setup provider based on chain
        await this.setupProvider();
        
        // Setup signer
        this.signer = new ethers.Wallet(this.chainConfig.privateKey, this.provider);
        
        console.log(`💰 Deployer address: ${this.signer.address}`);
        
        const balance = await this.provider.getBalance(this.signer.address);
        console.log(`💳 Balance: ${ethers.formatEther(balance)} ETH`);
        
        // Initialize nonce
        this.nonce = await this.provider.getTransactionCount(this.signer.address);
        console.log(`🔢 Starting nonce: ${this.nonce}`);
        
        // Verify sufficient balance for deployment
        const minBalance = ethers.parseEther(this.chainConfig.minBalance || '0.1');
        if (balance < minBalance) {
            throw new Error(`❌ Insufficient balance. Need at least ${this.chainConfig.minBalance || '0.1'} ETH for deployment`);
        }
    }

    async loadChainConfig() {
        console.log(`🔧 Loading configuration for chain: ${this.chain}`);
        
        // Load environment variables based on chain
        const envFile = `.env.${this.chain}`;
        const fs = require('fs');
        const path = require('path');
        
        const envPath = path.join(__dirname, envFile);
        if (fs.existsSync(envPath)) {
            console.log(`📄 Loading config from ${envFile}`);
            const envContent = fs.readFileSync(envPath, 'utf8');
            const envLines = envContent.split('\n').filter(line => line.trim() && !line.startsWith('#'));
            
            envLines.forEach(line => {
                const [key, ...valueParts] = line.split('=');
                if (key && valueParts.length > 0) {
                    const value = valueParts.join('=').trim();
                    process.env[key.trim()] = value;
                }
            });
        } else {
            console.log(`⚠️  No config file found at ${envFile}, using environment variables`);
        }

        // Set chain-specific configuration
        this.chainConfig = {
            rpcUrl: process.env.RPC_URL,
            privateKey: process.env.PRIVATE_KEY,
            minBalance: process.env.MIN_BALANCE || '0.001',
            gasLimit: parseInt(process.env.GAS_LIMIT || '2000000'),
            gameCreationFee: '0', // Zero creation fee for now
            deployGames: process.env.DEPLOY_GAMES === 'true',
        };

        // Validate required configuration
        if (!this.chainConfig.privateKey) {
            throw new Error(`❌ PRIVATE_KEY not set for chain ${this.chain}`);
        }

        if (this.chain !== 'localhost' && this.chain !== 'hardhat' && !this.chainConfig.rpcUrl) {
            throw new Error(`❌ RPC_URL not set for chain ${this.chain}`);
        }

        console.log(`✅ Configuration loaded for ${this.chain}`);
        if (this.chainConfig.rpcUrl) {
            console.log(`🌐 RPC URL: ${this.chainConfig.rpcUrl.substring(0, 50)}...`);
        }
        console.log(`⛽ Gas Limit: ${this.chainConfig.gasLimit}`);
        console.log(`💰 Min Balance: ${this.chainConfig.minBalance} ETH`);
    }

    async setupProvider() {
        console.log(`🔍 Setting up provider for chain: "${this.chain}"`);
        
        // Default to localhost for local development
        let rpcUrl = 'http://127.0.0.1:8545';
        
        if (this.chainConfig.rpcUrl) {
            rpcUrl = this.chainConfig.rpcUrl;
        } else if (this.chain !== 'localhost' && this.chain !== 'hardhat' && this.chain !== 'local') {
            throw new Error(`RPC_URL required for ${this.chain} deployment`);
        }
        
        console.log(`📡 Using RPC: ${rpcUrl}`);
        this.provider = new ethers.JsonRpcProvider(rpcUrl);
    }

    async compileContract(contractName) {
        console.log(`📝 Compiling ${contractName}...`);
        
        try {
            const contractPath = path.join(__dirname, '..', `${contractName}.sol`);
            const source = fs.readFileSync(contractPath, 'utf8');
            
            // Add import callback for OpenZeppelin contracts
            function findImports(importPath) {
                console.log(`🔍 Resolving import: ${importPath}`);
                try {
                    if (importPath.startsWith('@openzeppelin/contracts/')) {
                        // Try different possible locations for OpenZeppelin
                        const possiblePaths = [
                            path.join(__dirname, 'node_modules', importPath),
                            path.join(__dirname, '..', 'node_modules', importPath),
                            path.join(__dirname, '..', '..', 'node_modules', importPath),
                            path.join(process.cwd(), 'node_modules', importPath)
                        ];
                        
                        for (const ozPath of possiblePaths) {
                            if (fs.existsSync(ozPath)) {
                                console.log(`✅ Found OpenZeppelin contract at: ${ozPath}`);
                                const content = fs.readFileSync(ozPath, 'utf8');
                                return { contents: content };
                            }
                        }
                        
                        console.warn(`⚠️  OpenZeppelin contract not found: ${importPath}`);
                    }
                    
                    // Handle local imports
                    if (importPath.startsWith('./') || !importPath.includes('/')) {
                        const localPaths = [
                            path.join(__dirname, '..', importPath.replace('./', '')),
                            path.join(__dirname, '..', importPath),
                            path.join(__dirname, '..', './', importPath)
                        ];
                        
                        for (const localPath of localPaths) {
                            if (fs.existsSync(localPath)) {
                                console.log(`✅ Found local contract at: ${localPath}`);
                                const content = fs.readFileSync(localPath, 'utf8');
                                return { contents: content };
                            }
                        }
                        console.warn(`⚠️  Local contract not found: ${importPath}`);
                    }
                    
                } catch (e) {
                    console.warn(`⚠️  Error resolving import ${importPath}:`, e.message);
                }
                return { error: `File not found: ${importPath}` };
            }

            // Create input for solc
            const input = {
                language: 'Solidity',
                sources: {
                    [`${contractName}.sol`]: { content: source }
                },
                settings: {
                    outputSelection: {
                        '*': {
                            '*': ['abi', 'evm.bytecode.object', 'evm.gasEstimates']
                        }
                    },
                    optimizer: {
                        enabled: true,
                        runs: 200
                    },
                    evmVersion: 'london',
                    viaIR: false
                }
            };

            console.log(`🔧 Compiling with import callback...`);
            
            // Get detailed compiler version info
            const compilerVersion = this.solidityCompiler.version();
            const versionMatch = compilerVersion.match(/(\d+\.\d+\.\d+)/);
            const actualVersion = versionMatch ? versionMatch[1] : 'unknown';
            
            console.log(`📋 Solidity compiler version: ${compilerVersion}`);
            console.log(`📋 Extracted version: ${actualVersion}`);
            console.log(`📋 Target version: ${this.targetSolidityVersion || 'default'}`);
            console.log(`📋 EVM target version: london (for Cronos compatibility)`);
            console.log(`📋 Optimizer enabled: true (200 runs)`);
            
            // Check if we're using the right version for Cronos
            if (this.chain === 'cronos' && actualVersion !== '0.8.19') {
                console.log(`⚠️  WARNING: Cronos prefers Solidity 0.8.19, but using ${actualVersion}`);
                console.log(`💡 Consider running with: node deploy-complete.js --chain cronos --solidity-version v0.8.19+commit.7dd6d404`);
            }
            
            const output = JSON.parse(this.solidityCompiler.compile(JSON.stringify(input), { import: findImports }));
            
            if (output.errors) {
                const criticalErrors = output.errors.filter(error => error.severity === 'error');
                if (criticalErrors.length > 0) {
                    console.error(`❌ Compilation errors for ${contractName}:`);
                    criticalErrors.forEach(error => console.error(error.formattedMessage));
                    throw new Error(`Failed to compile ${contractName}`);
                }
                
                // Log warnings but don't fail
                const warnings = output.errors.filter(error => error.severity === 'warning');
                if (warnings.length > 0) {
                    console.warn(`⚠️  Compilation warnings for ${contractName}:`);
                    warnings.forEach(warning => console.warn(warning.formattedMessage));
                }
            }

            const contract = output.contracts[`${contractName}.sol`][contractName];
            if (!contract) {
                throw new Error(`Contract ${contractName} not found in compilation output`);
            }
            
            this.contractArtifacts[contractName] = {
                abi: contract.abi,
                bytecode: '0x' + contract.evm.bytecode.object
            };
            
            console.log(`✅ ${contractName} compiled successfully`);
            return this.contractArtifacts[contractName];
            
        } catch (error) {
            console.error(`❌ Failed to compile ${contractName}:`, error.message);
            throw error;
        }
    }

    getDependencies(source) {
        const importRegex = /import\s+['"](\.\/[^'"]+)['"]/g;
        const dependencies = [];
        let match;
        
        while ((match = importRegex.exec(source)) !== null) {
            dependencies.push(match[1].substring(2)); // Remove './'
        }
        
        return dependencies;
    }

    async deployContract(contractName, constructorArgs = [], existingAddress = null) {
        console.log(`\n📦 ${existingAddress ? 'Connecting to' : 'Deploying'} ${contractName}...`);
        
        try {
            // Compile if not already compiled (needed for ABI)
            if (!this.contractArtifacts[contractName]) {
                await this.compileContract(contractName);
            }
            
            const artifact = this.contractArtifacts[contractName];
            
            // If existing address provided, connect to existing contract
            if (existingAddress) {
                console.log(`🔗 Connecting to existing ${contractName} at: ${existingAddress}`);
                const contract = new ethers.Contract(existingAddress, artifact.abi, this.signer);
                
                this.contracts[contractName] = contract;
                this.deployedAddresses[contractName] = existingAddress;
                
                console.log(`✅ Connected to ${contractName} at: ${existingAddress}`);
                return contract;
            }
            
            // Deploy new contract
            const factory = new ethers.ContractFactory(
                artifact.abi,
                artifact.bytecode,
                this.signer
            );

            // Estimate gas
            const deployTx = await factory.getDeployTransaction(...constructorArgs);
            const gasEstimate = await this.provider.estimateGas(deployTx);
            const gasPrice = await this.provider.getFeeData();
            
            console.log(`⛽ Estimated gas: ${gasEstimate.toString()}`);
            console.log(`💰 Estimated cost: ${ethers.formatEther(gasEstimate * gasPrice.gasPrice)} ETH`);
            
            const contract = await factory.deploy(...constructorArgs, {
                gasLimit: gasEstimate + BigInt(50000), // Add buffer
                nonce: this.nonce // Use manual nonce
            });
            
            console.log(`📡 Transaction hash: ${contract.deploymentTransaction().hash}`);
            console.log(`🔢 Used nonce: ${this.nonce}`);
            
            // Increment nonce for next transaction
            this.nonce++;
            
            await contract.waitForDeployment();
            
            const address = await contract.getAddress();
            console.log(`✅ ${contractName} deployed at: ${address}`);
            
            this.contracts[contractName] = contract;
            this.deployedAddresses[contractName] = address;
            
            return contract;
        } catch (error) {
            console.error(`❌ Failed to ${existingAddress ? 'connect to' : 'deploy'} ${contractName}:`, error.message);
            
            // If deployment failed due to nonce issues, resync
            if (error.code === 'NONCE_EXPIRED' || error.code === 'REPLACEMENT_UNDERPRICED') {
                console.log('🔄 Resyncing nonce due to deployment error...');
                await this.resyncNonce();
            }
            
            throw error;
        }
    }

    async sendTransaction(contract, methodName, args = [], value = 0) {
        console.log(`📤 Sending transaction: ${methodName} with nonce ${this.nonce}`);
        
        try {
            // Estimate gas for the specific transaction
            let gasEstimate;
            try {
                gasEstimate = await contract[methodName].estimateGas(...args, { value: value || 0 });
                console.log(`⛽ Estimated gas for ${methodName}: ${gasEstimate.toString()}`);
            } catch (error) {
                console.warn(`⚠️  Gas estimation failed for ${methodName}, using default: ${error.message}`);
                gasEstimate = BigInt(100000); // Conservative fallback for setter functions
            }
            
            // Add 20% buffer to gas estimate
            const gasLimit = gasEstimate + (gasEstimate / BigInt(5));
            console.log(`⛽ Gas limit (with 20% buffer): ${gasLimit.toString()}`);
            
            // Get current gas price for cost estimation
            const feeData = await this.provider.getFeeData();
            const estimatedCost = gasLimit * feeData.gasPrice;
            console.log(`💰 Estimated transaction cost: ${ethers.formatEther(estimatedCost)} ETH`);
            
            const txOptions = {
                nonce: this.nonce,
                gasLimit: gasLimit
            };
            
            if (value > 0) {
                txOptions.value = value;
            }
            
            const tx = await contract[methodName](...args, txOptions);
            console.log(`📡 Transaction hash: ${tx.hash}`);
            
            // Increment nonce for next transaction
            this.nonce++;
            
            const receipt = await tx.wait();
            console.log(`✅ Transaction confirmed with nonce: ${receipt.nonce}`);
            console.log(`⛽ Actual gas used: ${receipt.gasUsed.toString()}`);
            console.log(`💰 Gas efficiency: ${((Number(receipt.gasUsed) / Number(gasLimit)) * 100).toFixed(1)}%`);
            
            // Calculate actual cost
            const actualCost = receipt.gasUsed * receipt.gasPrice;
            console.log(`💰 Actual transaction cost: ${ethers.formatEther(actualCost)} ETH`);
            
            return receipt;
        } catch (error) {
            console.error(`❌ Transaction failed: ${methodName}`, error.message);
            
            // If transaction failed, we might need to resync nonce
            if (error.code === 'NONCE_EXPIRED' || error.code === 'REPLACEMENT_UNDERPRICED') {
                console.log('🔄 Resyncing nonce due to transaction error...');
                await this.resyncNonce();
            }
            
            throw error;
        }
    }

    async resyncNonce() {
        const currentNonce = await this.provider.getTransactionCount(this.signer.address);
        console.log(`🔢 Nonce resync: ${this.nonce} -> ${currentNonce}`);
        this.nonce = currentNonce;
    }

    async deployOrConnectToCore() {
        console.log('\n🏗️  Deploying Core Onchain Game Contracts...');
        
        // Existing production contract addresses (for Cronos deployment)
        const existingAddresses = {
            OnchainGameManager: '0xD937BDe512fEb09A528212dF6Cd2eC3682fbdc9A',
            OnchainGameEarnings: '0x48bC0aFBDF84219c41EE76f058076082f2F827B2',
            OnchainGameLeaderboard: '0x26925DFB91D87b30b99725F46ab2D0a096799a16',
            ScratchCardGame: '0x1E446f9e4673d7a35b9852bD90f39484FE761FF4',
            MultiplierWithScore: '0xbE16e103D161F8a65812A3aeF0FD1aA0DBF4C7DB'
        };
        
        // 1. Deploy TokenWhitelist (optional but recommended)
        //await this.deployContract('TokenWhitelist');
        
        // 2. Connect to existing main contracts if on Cronos, otherwise deploy new ones
        const useCronosAddresses = this.chain === 'cronos';
        
        await this.deployContract('OnchainGameManager', [], 
            useCronosAddresses ? existingAddresses.OnchainGameManager : null);
        await this.deployContract('OnchainGameEarnings', [], 
            useCronosAddresses ? existingAddresses.OnchainGameEarnings : null);
        await this.deployContract('OnchainGameLeaderboard', [], 
            useCronosAddresses ? existingAddresses.OnchainGameLeaderboard : null);
        
        console.log('✅ Core contracts setup successfully!');
    }

    async configureContracts() {
        console.log('\n⚙️  Configuring Contract Cross-References...');
        
        const manager = this.contracts.OnchainGameManager;
        const earnings = this.contracts.OnchainGameEarnings;
        const leaderboard = this.contracts.OnchainGameLeaderboard;

        try {
            // Configure Manager contract references
            console.log('🔗 Setting earnings contract in manager...');
            await this.sendTransaction(manager, 'setEarningsContract', [this.deployedAddresses.OnchainGameEarnings]);
            
            console.log('🔗 Setting leaderboard contract in manager...');
            await this.sendTransaction(manager, 'setLeaderboardContract', [this.deployedAddresses.OnchainGameLeaderboard]);
            
            // if (whitelist) {
            //     console.log('🔗 Setting token whitelist in manager...');
            //     await this.sendTransaction(manager, 'setTokenWhitelist', [this.deployedAddresses.TokenWhitelist]);
            // }

            // Configure Earnings contract references
            console.log('🔗 Setting manager in earnings...');
            await this.sendTransaction(earnings, 'setOnchainGameManager', [this.deployedAddresses.OnchainGameManager]);
            
            console.log('🔗 Setting leaderboard in earnings...');
            await this.sendTransaction(earnings, 'setLeaderboardContract', [this.deployedAddresses.OnchainGameLeaderboard]);

            // Configure Leaderboard contract references
            console.log('🔗 Setting manager in leaderboard...');
            await this.sendTransaction(leaderboard, 'setOnchainGameManager', [this.deployedAddresses.OnchainGameManager]);
            
            console.log('🔗 Setting earnings in leaderboard...');
            await this.sendTransaction(leaderboard, 'setEarningsContract', [this.deployedAddresses.OnchainGameEarnings]);

            console.log('✅ All contract references configured successfully!');
        } catch (error) {
            console.error('❌ Failed to configure contracts:', error.message);
            throw error;
        }
    }

    async deployGameType(gameTypeName) {
        console.log('\n🎮 Deploying Game Type Contracts...');
        
        const contractName = gameTypeName + 'Game';
        const useCronosAddresses = this.chain === 'cronos';
        
        await this.deployContract(contractName, [this.deployedAddresses.OnchainGameManager], null);
        
        console.log('✅ Game type contracts setup successfully!');
    }

    async registerGameType(gameTypeName) {
        console.log('\n📝 Registering Game Type in Manager...');
        
        const manager = this.contracts.OnchainGameManager;
        
        try {
            // Pre-registration checks
            console.log('\n🔍 Pre-registration diagnostic checks...');
            
            // Check if we're the owner
            try {
                const owner = await manager.owner();
                console.log(`📋 Contract owner: ${owner}`);
                console.log(`📋 Deployer address: ${this.signer.address}`);
                console.log(`📋 Is deployer owner: ${owner.toLowerCase() === this.signer.address.toLowerCase()}`);
            } catch (error) {
                console.log(`❌ Failed to get owner: ${error.message}`);
            }
            // Check game contract address
            const contractName = gameTypeName + 'Game';
            console.log(`📋 ${contractName} address: ${this.deployedAddresses[contractName]}`);

            // Check if game type is already registered
            try {
                const existingGameType = await manager.gameTypes(gameTypeName);
                console.log(`📋 Existing ${gameTypeName} registration:`);
                console.log(`   - Contract: ${existingGameType.contractAddress}`);
                console.log(`   - Already registered: ${existingGameType.contractAddress !== '0x0000000000000000000000000000000000000000'}`);
            } catch (error) {
                console.log(`❌ Failed to check existing registration: ${error.message}`);
            }
            
            // Check current game type names
            try {
                const gameTypes = await manager.getAllGameTypeNames();
                console.log(`📋 Current game types: [${gameTypes.join(', ')}]`);
            } catch (error) {
                console.log(`� getAllGameTypeNames still failing: ${error.message}`);
            }
            
            // Register game type
            console.log(`\n📝 Attempting to register ${gameTypeName} game type...`);
            const creationFee = ethers.parseEther(this.chainConfig.gameCreationFee);
            console.log(`📋 Creation fee: ${ethers.formatEther(creationFee)} ETH`);
            
            await this.sendTransaction(manager, 'registerGameType', [
                gameTypeName,
                this.deployedAddresses[contractName],
                creationFee,
                true // allow native token onchain
            ]);
            
            console.log(`✅ ${gameTypeName} game type registered successfully!`);
        } catch (error) {
            console.error('❌ Failed to register game types:', error.message);
            throw error;
        }
    }

    async updateGameContract(gameTypeName) {
        console.log(`\n🔄 Updating Game Contract for ${gameTypeName}...`);
        
        try {
            // 1. Deploy or connect to core contracts first
            await this.deployOrConnectToCore();
            
            // 2. Compile and deploy the new game contract
            const contractName = gameTypeName + 'Game';
            console.log(`📝 Compiling and deploying new ${contractName} contract...`);
            
            await this.deployContract(contractName, [this.deployedAddresses.OnchainGameManager], null);
            
            // 3. Update the game type contract address in the manager
            const manager = this.contracts.OnchainGameManager;
            console.log(`🔗 Updating ${gameTypeName} contract address in manager...`);
            
            await this.sendTransaction(manager, 'updateGameTypeContract', [
                gameTypeName,
                this.deployedAddresses[contractName]
            ]);
            
            console.log(`✅ ${gameTypeName} game contract updated successfully!`);
            console.log(`📋 New contract address: ${this.deployedAddresses[contractName]}`);
            
            // 4. Save deployment info
            await this.saveDeploymentInfo();
            
            return {
                gameType: gameTypeName,
                contractName: contractName,
                newAddress: this.deployedAddresses[contractName],
                chain: this.chain
            };
            
        } catch (error) {
            console.error(`❌ Failed to update ${gameTypeName} game contract:`, error.message);
            throw error;
        }
    }

    async diagnoseContracts() {
        console.log('\n🔬 Diagnosing Contract Connectivity...');
        
        const manager = this.contracts.OnchainGameManager;
        const managerAddress = this.deployedAddresses.OnchainGameManager;
        
        try {
            // First, check if there's any code at the contract address
            console.log(`🔍 Checking contract existence at: ${managerAddress}`);
            const code = await this.provider.getCode(managerAddress);
            
            if (code === '0x') {
                console.log('❌ NO CONTRACT CODE found at OnchainGameManager address!');
                console.log('🚨 This means the contract does not exist at this address');
                return;
            } else {
                console.log(`✅ Contract code exists (${code.length} bytes)`);
            }
            
            // Test basic contract connectivity with a simple call
            console.log('\n🔍 Testing basic contract calls...');
            
            try {
                const leaderboardAddr = await manager.leaderboardContract();
                console.log(`✅ leaderboardContract call works: ${leaderboardAddr}`);
            } catch (error) {
                console.log(`❌ leaderboardContract call failed: ${error.message}`);
                console.log(`Error code: ${error.code || 'undefined'}`);
                console.log(`Error data: ${error.data || 'undefined'}`);
            }
            
            try {
                const earningsAddr = await manager.earningsContract();
                console.log(`✅ earningsContract call works: ${earningsAddr}`);
            } catch (error) {
                console.log(`❌ earningsContract call failed: ${error.message}`);
            }
            
            try {
                const gameCount = await manager.gameCount();
                console.log(`✅ gameCount call works: ${gameCount}`);
            } catch (error) {
                console.log(`❌ gameCount call failed: ${error.message}`);
            }
            
            try {
                const restrictGameCreation = await manager.restrictGameCreation();
                console.log(`✅ restrictGameCreation call works: ${restrictGameCreation}`);
            } catch (error) {
                console.log(`❌ restrictGameCreation call failed: ${error.message}`);
            }
            
            // Test the problematic getAllGameTypeNames call
            try {
                console.log('\n🔍 Testing getAllGameTypeNames...');
                const gameTypes = await manager.getAllGameTypeNames();
                console.log(`✅ getAllGameTypeNames works: [${gameTypes.join(', ')}]`);
            } catch (error) {
                console.log(`❌ getAllGameTypeNames failed: ${error.message}`);
                console.log(`Error code: ${error.code || 'undefined'}`);
                console.log(`Transaction data: ${error.data || 'undefined'}`);
            }
            
            console.log('\n🔍 Network connectivity check...');
            console.log(`🌐 Chain: ${this.chain}`);
            console.log(`📡 RPC URL: ${this.chainConfig.rpcUrl || 'localhost'}`);
            
            // Test provider connectivity
            try {
                const blockNumber = await this.provider.getBlockNumber();
                console.log(`✅ Provider connected, current block: ${blockNumber}`);
            } catch (error) {
                console.log(`❌ Provider connection failed: ${error.message}`);
            }
            
        } catch (error) {
            console.error('❌ Contract diagnosis failed:', error.message);
            throw error;
        }
    }

    async verifyDeployment(includeGames) {
        console.log('\n🔍 Verifying Deployment...');
        
        const manager = this.contracts.OnchainGameManager;
        
        try {
            // Check contract cross-references
            const earningsAddr = await manager.earningsContract();
            const leaderboardAddr = await manager.leaderboardContract();
            
            console.log(`📊 Earnings contract: ${earningsAddr}`);
            console.log(`🏆 Leaderboard contract: ${leaderboardAddr}`);
            
            // Verify contract linking
            if (earningsAddr !== this.deployedAddresses.OnchainGameEarnings) {
                throw new Error('Earnings contract not properly linked');
            }
            if (leaderboardAddr !== this.deployedAddresses.OnchainGameLeaderboard) {
                throw new Error('Leaderboard contract not properly linked');
            }
            
            // Check registered game types
            const gameTypes = await manager.getAllGameTypeNames();
            console.log(`🎮 Registered game types: ${gameTypes.join(', ')}`);
            
             if (includeGames) {
                // Test a game info retrieval
                const gameInfo = await manager.getGameInfo(1);
                console.log(`🎯 Sample game "${gameInfo}" info verified`);
             }
            
            console.log('✅ Deployment verification completed successfully!');
        } catch (error) {
            console.error('❌ Deployment verification failed:', error.message);
            throw error;
        }
    }

    async saveDeploymentInfo() {
        const deploymentInfo = {
            chain: this.chain,
            network: this.network, // Keep for backward compatibility
            deployer: this.signer.address,
            timestamp: new Date().toISOString(),
            deploymentVersion: '2.0.0',
            architecture: 'three-contract-optimized',
            contracts: this.deployedAddresses,
            features: [
                'weighted-jackpot-selection',
                'single-source-statistics',
                'fee-structure-10-10-remainder',
                'event-based-history',
                'gas-optimized'
            ],
            notes: {
                feeStructure: 'Creator 10%, Owner 10%, House gets remainder',
                jackpotTrigger: '50% probability on manual trigger',
                jackpotSelection: 'Weighted by player period scores',
                gasOptimizations: 'Removed on-chain history, single winner system'
            }
        };

        const fileName = `deployment-${this.network}-${Date.now()}.json`;
        fs.writeFileSync(fileName, JSON.stringify(deploymentInfo, null, 2));
        console.log(`💾 Deployment info saved to: ${fileName}`);
        
        // Also save a chain-specific file for easy access by other scripts
        const chainFileName = `deployment-${this.chain}.json`;
        fs.writeFileSync(chainFileName, JSON.stringify(deploymentInfo, null, 2));
        console.log(`💾 Chain deployment info saved to: ${chainFileName}`);
        
        // Update frontend constant files with new addresses and ABIs
        await this.updateFrontendConstants();
        
        return deploymentInfo;
    }

    async updateFrontendConstants() {
        console.log('\n📝 Updating frontend constant files...');
        
        try {
            const constantsPath = path.join(__dirname, '..', '..', '..', 'util', 'constants');
            
            // Update OnchainGameManager constants
            if (this.deployedAddresses.OnchainGameManager && this.contractArtifacts.OnchainGameManager) {
                await this.updateConstantFile(
                    path.join(constantsPath, 'onchainGameManager.js'),
                    this.deployedAddresses.OnchainGameManager,
                    this.contractArtifacts.OnchainGameManager.abi,
                    'OnchainGameManager'
                );
            }
            
            // Update OnchainGameEarnings constants
            if (this.deployedAddresses.OnchainGameEarnings && this.contractArtifacts.OnchainGameEarnings) {
                await this.updateConstantFile(
                    path.join(constantsPath, 'onchainGameEarnings.js'),
                    this.deployedAddresses.OnchainGameEarnings,
                    this.contractArtifacts.OnchainGameEarnings.abi,
                    'OnchainGameEarnings'
                );
            }
            
            // Update OnchainGameLeaderboard constants
            if (this.deployedAddresses.OnchainGameLeaderboard && this.contractArtifacts.OnchainGameLeaderboard) {
                await this.updateConstantFile(
                    path.join(constantsPath, 'onchainGameLeaderboard.js'),
                    this.deployedAddresses.OnchainGameLeaderboard,
                    this.contractArtifacts.OnchainGameLeaderboard.abi,
                    'OnchainGameLeaderboard'
                );
            }
            
            // Update MultiplierWithScoreGame constants
            if (this.deployedAddresses.MultiplierWithScoreGame && this.contractArtifacts.MultiplierWithScoreGame) {
                await this.updateConstantFile(
                    path.join(constantsPath, 'multiplierWithScoreGame.js'),
                    this.deployedAddresses.MultiplierWithScoreGame,
                    this.contractArtifacts.MultiplierWithScoreGame.abi,
                    'MultiplierWithScoreGame'
                );
            }
            
            // Update ScratchCardGame constants (if deployed)
            if (this.deployedAddresses.ScratchCardGame && this.contractArtifacts.ScratchCardGame) {
                await this.updateConstantFile(
                    path.join(constantsPath, 'scratchCardGame.js'),
                    this.deployedAddresses.ScratchCardGame,
                    this.contractArtifacts.ScratchCardGame.abi,
                    'ScratchCardGame'
                );
            }
            
            // Update TestToken constants (if deployed)
            if (this.deployedAddresses.TestToken && this.contractArtifacts.TestToken) {
                await this.updateConstantFile(
                    path.join(constantsPath, 'testToken.js'),
                    this.deployedAddresses.TestToken,
                    this.contractArtifacts.TestToken.abi,
                    'TestToken'
                );
            }
            
            console.log('✅ Frontend constant files updated successfully!');
            
        } catch (error) {
            console.error('❌ Failed to update frontend constants:', error.message);
            console.log('ℹ️  Please update constant files manually');
        }
    }

    async updateConstantFile(filePath, contractAddress, abi, contractName) {
        // Use multi-chain pattern - read existing file and update the chain-specific address
        const chainName = this.chain;
        const getterFunctionName = `get${contractName}Address`;
        
        try {
            let existingAddresses = {};
            
            // Try to read existing file and extract CONTRACT_ADDRESSES
            if (fs.existsSync(filePath)) {
                const existingContent = fs.readFileSync(filePath, 'utf8');
                
                // Extract existing CONTRACT_ADDRESSES object using regex
                const addressMatch = existingContent.match(/const CONTRACT_ADDRESSES\s*=\s*\{([^}]+)\}/);
                if (addressMatch) {
                    // Parse the existing addresses
                    const addressBlock = addressMatch[1];
                    const addressLines = addressBlock.match(/(\w+):\s*['"]([^'"]+)['"]/g);
                    if (addressLines) {
                        addressLines.forEach(line => {
                            const match = line.match(/(\w+):\s*['"]([^'"]+)['"]/);
                            if (match) {
                                existingAddresses[match[1]] = match[2];
                            }
                        });
                    }
                }
            }
            
            // Add/update the address for current chain
            existingAddresses[chainName] = contractAddress;
            
            // Build the CONTRACT_ADDRESSES object string
            const addressEntries = Object.entries(existingAddresses)
                .map(([chain, addr]) => `  ${chain}: '${addr}'`)
                .join(',\n');
            
            // Generate the new file content with multi-chain pattern
            const constantFileContent = `// ${contractName} contract configuration
// Contract addresses per chain
const CONTRACT_ADDRESSES = {
${addressEntries}
}

// Contract address getter function
export function ${getterFunctionName}(chainName = 'cronos') {
  return CONTRACT_ADDRESSES[chainName] || null
}

// Legacy export for backward compatibility
export const contractAddress = CONTRACT_ADDRESSES.cronos || CONTRACT_ADDRESSES.${chainName}

export const ABI = ${JSON.stringify(abi, null, '\t')};
`;

            fs.writeFileSync(filePath, constantFileContent);
            console.log(`   ✅ Updated ${path.basename(filePath)} (added ${chainName} address)`);
            console.log(`      📍 ${chainName}: ${contractAddress}`);
            
        } catch (error) {
            console.error(`   ❌ Failed to update ${path.basename(filePath)}: ${error.message}`);
            // Fallback to simple overwrite if parsing fails
            const constantFileContent = `// ${contractName} contract configuration
// Contract addresses per chain
const CONTRACT_ADDRESSES = {
  ${chainName}: '${contractAddress}'
}

// Contract address getter function
export function ${getterFunctionName}(chainName = 'cronos') {
  return CONTRACT_ADDRESSES[chainName] || null
}

// Legacy export for backward compatibility
export const contractAddress = CONTRACT_ADDRESSES.${chainName}

export const ABI = ${JSON.stringify(abi, null, '\t')};
`;
            fs.writeFileSync(filePath, constantFileContent);
            console.log(`   ⚠️  Updated ${path.basename(filePath)} (fallback mode - ${chainName} only)`);
        }
    }

    async createToken() {
        console.log('\n🪙 Deploying TEST Token...');
        
        try {
            // Deploy TEST test token for frontend testing
            const tokenSupply = ethers.parseEther('10000000'); // 10M tokens
            const tokenContract = await this.deployContract('TestToken', [
                tokenSupply,
                'TEST',          // name
                'TEST',          // symbol
                18              // decimals
            ]);
            
            const tokenAddress = await tokenContract.getAddress();
            
            console.log(`✅ TEST Token deployed`);
            console.log(`🏦 Address: ${tokenAddress}`);
            console.log(`💰 Total Supply: 10M TEST`);
            
            return tokenAddress;
            
        } catch (error) {
            console.error(`❌ Failed to deploy TEST token:`, error.message);
            throw error;
        }
    }

    async createGame(gameTypeName = 'ScratchCard') {
        console.log(`\n🎮 Creating TEST ${gameTypeName} Game...`);
        
        if (!this.deployedAddresses.TestToken) {
            throw new Error('TEST Token must be deployed before creating the game');
        }
        
        try {
            const manager = this.contracts.OnchainGameManager;
            
            // First, authorize the deployer to create games
            console.log('🔑 Authorizing deployer as game creator...');
            await this.sendTransaction(manager, 'setCreatorAuthorization', [this.signer.address, true]);
            console.log('✅ Deployer authorized successfully');
            
            // Verify authorization
            const isAuthorized = await manager.isAuthorizedCreator(this.signer.address);
            console.log(`🔍 Deployer authorization check: ${isAuthorized}`);
            
            // Check if game type exists
            try {
                const gameTypeInfo = await manager.getGameTypeInfo(gameTypeName);
                console.log(`✅ ${gameTypeName} game type found: ${gameTypeInfo[0]}`);
                console.log(`💰 Creation fee: ${ethers.formatEther(gameTypeInfo[1])} ETH`);
                console.log(`🪙 Allows native token: ${gameTypeInfo[2]}`);
            } catch (error) {
                console.log(`❌ ${gameTypeName} game type not found: ${error.message}`);
                throw new Error(`${gameTypeName} game type must be registered before creating games`);
            }
            
            // Game configuration
            const betAmounts = [
                ethers.parseEther('10'),     // 10 TEST
                ethers.parseEther('50'),     // 50 TEST
                ethers.parseEther('100'),    // 100 TEST
                ethers.parseEther('500'),    // 500 TEST
                ethers.parseEther('1000')    // 1000 TEST
            ];
            
            // Create game parameters as a struct object
            const gameParams = {
                gameID: 0,
                gameName: 'TEST',
                gameTypeName: gameTypeName,
                tokenAddress: this.deployedAddresses.TestToken,
                allowedBets: betAmounts,
                useNativeToken: false,
                creator: ethers.ZeroAddress, // Will use msg.sender
                jackpotEnabled: true,
                jackpotDuration: 24 * 7, // 7 days in hours
                jackpotTopPlayers: 30
            };

            console.log(`📤 Creating TEST game...`);
            
            const createTx = await this.sendTransaction(manager, 'createGame', [gameParams], ethers.parseEther('0.01'));

            // find the GameCreated event
            const gameCreatedEvent = createTx.logs
            .map(log => {
                try {
                return manager.interface.parseLog(log);
                } catch {
                return null; // skip logs that don't match this contract
                }
            })
            .filter(e => e && e.name === "GameCreated")[0];

            if (gameCreatedEvent) {
                const gameID = gameCreatedEvent.args.gameID;
                console.log("Game ID:", gameID.toString());
            }
            // Configure jackpot for the TEST game
            console.log(`⚙️ Configuring jackpot for TEST game...`);
            const leaderboard = this.contracts.OnchainGameLeaderboard;
            await this.sendTransaction(leaderboard, 'configureJackpot', [
                1,     // gameName
                24 * 7,    // 7 days in hours
                30         // Top 10 players
            ]);
            
            console.log(`✅ TEST game created successfully!`);
            console.log(`💰 Bet amounts: ${betAmounts.map(b => ethers.formatEther(b)).join(', ')} TEST`);
            console.log('🎰 Jackpot enabled with 7-day cycles');
            console.log('🏆 Top 10 players eligible for jackpot');
            
            // Transfer game ownership to testing address
            console.log(`🔄 Transferring game ownership to testing address...`);
            const testingAddress = '0x563bF29e4b5fB2Cd82FB255462cee6B531cF9E65';
            await this.sendTransaction(manager, 'transferGameOwnership', [1, testingAddress]);
            console.log(`✅ Game ownership transferred to: ${testingAddress}`);
            
        } catch (error) {
            console.error(`❌ Failed to create TEST game:`, error.message);
            throw error;
        }
    }

    async fundGame() {
        console.log('\n💰 Funding TEST Game...');
        
        if (!this.deployedAddresses.TestToken) {
            throw new Error('TEST Token must be deployed before funding the game');
        }
        
        try {
            const token = this.contracts.TestToken;
            const earnings = this.contracts.OnchainGameEarnings;
            const fundAmount = ethers.parseEther('100000'); // 100k TEST tokens
            
            // Check token balance
            const deployerBalance = await token.balanceOf(this.signer.address);
            console.log(`📊 Deployer TEST balance: ${ethers.formatEther(deployerBalance)} TEST`);
            console.log(`📊 Fund amount: ${ethers.formatEther(fundAmount)} TEST`);
            
            if (deployerBalance < fundAmount) {
                throw new Error(`Insufficient TEST tokens: have ${ethers.formatEther(deployerBalance)}, need ${ethers.formatEther(fundAmount)}`);
            }
            
            // Approve tokens for the earnings contract
            console.log(`📤 Approving tokens for earnings contract...`);
            await this.sendTransaction(token, 'approve', [this.deployedAddresses.OnchainGameEarnings, fundAmount]);
            
            // Verify allowance
            const allowance = await token.allowance(this.signer.address, this.deployedAddresses.OnchainGameEarnings);
            console.log(`✅ Allowance set: ${ethers.formatEther(allowance)} TEST`);
            
            // Fund the game
            console.log(`📤 Funding TEST game...`);
            await this.sendTransaction(earnings, 'fundGame', [1, fundAmount]);
            
            // Verify funding
            const gameBalance = await earnings.getGameBalance(1);
            console.log(`✅ TEST game funded successfully!`);
            console.log(`💰 Game balance: ${gameBalance} TEST`);
            
        } catch (error) {
            console.error(`❌ Failed to fund TEST game:`, error.message);
            throw error;
        }
    }

    async setupGames(gameTypeName = 'ScratchCard') {
        console.log('=' .repeat(60));
        
        try {
            // Deploy TEST token
            await this.createToken();
            
            // Create TEST game
            await this.createGame(gameTypeName);
            
            // Fund the TEST game
            await this.fundGame();
        
            console.log('\n✅ TEST Token and Game setup completed successfully!');
            console.log('🎮 Frontend testing environment is ready');
            
        } catch (error) {
            console.error('\n❌ TEST Token and Game setup failed:', error.message);
            throw error;
        }
    }

    async deploy(includeGames = false) {
        const startTime = Date.now();
        
        try {
            console.log('\n🎯 Starting Complete Onchain Game System Deployment');
            console.log('=' .repeat(60));
            
            await this.initialize();
            await this.deployOrConnectToCore();
            await this.configureContracts();
            await this.deployGameType('MultiplierWithScore');
            await this.registerGameType('MultiplierWithScore');
            
            
            await this.deployGameType('ScratchCard');
            await this.registerGameType('ScratchCard');
            // Diagnose contract connectivity before verification
            //await this.diagnoseContracts();
            
            // Optionally setup TEST token and game for frontend testing
            if (includeGames) {
                await this.setupGames('MultiplierWithScore');
            }
            
            await this.verifyDeployment(includeGames);
            
            const deploymentInfo = await this.saveDeploymentInfo();
            
            const duration = ((Date.now() - startTime) / 1000).toFixed(2);
            
            console.log('\n🎉 DEPLOYMENT COMPLETED SUCCESSFULLY! 🎉');
            console.log('=' .repeat(60));
            console.log(`⏱️  Total time: ${duration} seconds`);
            console.log(`🌐 Network: ${this.network}`);
            console.log(`👤 Deployer: ${this.signer.address}`);
            
            console.log('\n📋 Contract Addresses:');
            console.log('-' .repeat(40));
            for (const [name, address] of Object.entries(this.deployedAddresses)) {
                console.log(`   ${name.padEnd(25)}: ${address}`);
            }
            
            
            return deploymentInfo;
            
        } catch (error) {
            console.error('\n💥 DEPLOYMENT FAILED');
            console.error('=' .repeat(60));
            console.error(`Error: ${error.message}`);
            
            if (error.stack) {
                console.error('\nStack trace:');
                console.error(error.stack);
            }
            
            process.exit(1);
        }
    }
}

// Export for use as module
module.exports = CompleteOnchainGameDeployer;

// Run deployment if this script is executed directly
if (require.main === module) {
    // Parse command line arguments
    const args = process.argv.slice(2);
    let chain = null;
    let includeGames = false;
    let solidityVersion = null;
    let updateGameType = null;
    let healthCheck = false;
    
    // Parse --chain argument
    const chainIndex = args.findIndex(arg => arg === '--chain');
    if (chainIndex !== -1 && chainIndex + 1 < args.length) {
        chain = args[chainIndex + 1];
    }
    
    // Parse --solidity-version argument
    const solidityIndex = args.findIndex(arg => arg === '--solidity-version');
    if (solidityIndex !== -1 && solidityIndex + 1 < args.length) {
        solidityVersion = args[solidityIndex + 1];
    }
    
    // Parse --update-game-contract argument
    const updateIndex = args.findIndex(arg => arg === '--update-game-contract');
    if (updateIndex !== -1 && updateIndex + 1 < args.length) {
        updateGameType = args[updateIndex + 1];
    }
    
    // Check for --with-games flag
    includeGames = args.includes('--with-games');
    
    // Check for --health-check flag
    healthCheck = args.includes('--health-check');
    
    const deployer = new CompleteOnchainGameDeployer(chain, solidityVersion);
    
    // Show what chain will be used
    const actualChain = chain || process.env.CHAIN || 'localhost';
    if (!chain) {
        console.log(`ℹ️  No --chain specified, using default: ${actualChain}`);
    }
    
    // Show usage info
    if (solidityVersion) {
        console.log(`🔧 Using Solidity compiler version: ${solidityVersion}`);
    }
    
    // Handle different execution modes
    if (healthCheck) {
        // Health check mode - just show wallet info and balance
        console.log('\n🏥 HEALTH CHECK MODE');
        console.log('=' .repeat(60));
        deployer.initialize().then(async () => {
            console.log('\n✅ Health check completed successfully!');
            console.log('=' .repeat(60));
            console.log(`🌐 Chain: ${actualChain}`);
            console.log(`📡 RPC URL: ${deployer.chainConfig.rpcUrl || 'localhost'}`);
            console.log(`👛 Wallet Address: ${deployer.signer.address}`);
            
            const balance = await deployer.provider.getBalance(deployer.signer.address);
            console.log(`💰 Balance: ${ethers.formatEther(balance)} ${actualChain === 'bsc' ? 'BNB' : 'ETH'}`);
            
            const minBalance = ethers.parseEther(deployer.chainConfig.minBalance || '0.1');
            if (balance >= minBalance) {
                console.log(`✅ Sufficient balance for deployment (min: ${deployer.chainConfig.minBalance || '0.1'})`);
            } else {
                console.log(`⚠️  WARNING: Balance below minimum for deployment (min: ${deployer.chainConfig.minBalance || '0.1'})`);
            }
            
            // Check current block
            const blockNumber = await deployer.provider.getBlockNumber();
            console.log(`📦 Current Block: ${blockNumber}`);
            
            // Check gas price
            const feeData = await deployer.provider.getFeeData();
            console.log(`⛽ Gas Price: ${ethers.formatUnits(feeData.gasPrice, 'gwei')} gwei`);
            
            console.log('\n💡 Ready to deploy? Run without --health-check');
        }).catch((error) => {
            console.error('\n❌ Health check failed');
            console.error('=' .repeat(60));
            console.error(`Error: ${error.message}`);
            process.exit(1);
        });
    } else if (updateGameType) {
        console.log(`🔄 Updating ${updateGameType} game contract on ${actualChain}...`);
        deployer.initialize().then(() => deployer.updateGameContract(updateGameType)).then((result) => {
            console.log('\n🎉 GAME CONTRACT UPDATE COMPLETED SUCCESSFULLY! 🎉');
            console.log('=' .repeat(60));
            console.log(`🎮 Game Type: ${result.gameType}`);
            console.log(`📝 Contract: ${result.contractName}`);
            console.log(`🌐 Network: ${result.chain}`);
            console.log(`📍 New Address: ${result.newAddress}`);
        }).catch((error) => {
            console.error('\n💥 GAME CONTRACT UPDATE FAILED');
            console.error('=' .repeat(60));
            console.error(`Error: ${error.message}`);
            if (error.stack) {
                console.error('\nStack trace:');
                console.error(error.stack);
            }
            process.exit(1);
        });
    } else if (includeGames) {
        console.log(`🎮 Running ${actualChain} deployment with TEST token and game setup...`);
        deployer.deploy(true);
    } else {
        console.log(`🏗️  Running ${actualChain} basic deployment (use --with-games to include TEST token and game)...`);
        console.log(`💡 Available options:`);
        console.log(`   --chain <network>              Target blockchain (bsc, cronos, localhost, etc.)`);
        console.log(`   --solidity-version <ver>       Specific compiler version (e.g., v0.8.19+commit.7dd6d404)`);
        console.log(`   --with-games                   Include TEST token and game setup`);
        console.log(`   --update-game-contract <type>  Update existing game type contract (e.g., MultiplierWithScore)`);
        console.log(`   --health-check                 Check wallet address and balance without deploying`);
        deployer.deploy(false);
    }
}
