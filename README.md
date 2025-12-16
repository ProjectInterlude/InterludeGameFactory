# Onchain Games Contracts

A modular smart contract system for onchain gaming with support for multiple game types, leaderboards, and jackpots. Currently available on Cronos chain and BSC Chain (Binance Smart Chain/ BNB Chain).

## Architecture

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                           OnchainGameManager                                │
│                     (Central registry & game creation)                      │
└─────────────────────────────────────────────────────────────────────────────┘
                    │                    │                    │
                    ▼                    ▼                    ▼
    ┌───────────────────┐  ┌───────────────────┐  ┌───────────────────────┐
    │ OnchainGameEarnings│  │OnchainGameLeaderboard│  │   Game Contracts     │
    │   (Fund mgmt)      │  │  (Rankings/Jackpot) │  │ (MultiplierWithScore,│
    │                    │  │                     │  │   ScratchCard, etc)  │
    └───────────────────┘  └───────────────────┘  └───────────────────────┘
```

## Contracts

| Contract | Description |
|----------|-------------|
| `OnchainGameManager.sol` | Central registry for games and game types |
| `OnchainGameEarnings.sol` | Handles player earnings, house funds, and fee distribution |
| `OnchainGameLeaderboard.sol` | Manages player rankings and jackpot distribution |
| `MultiplierWithScoreGame.sol` | Two-phase game: draw multiplier → apply score |
| `ScratchCardGame.sol` | Single-phase instant win scratch card game |
| `TestToken.sol` | ERC20 token for testing |
| `TokenWhitelist.sol` | Token approval registry |

## Installation

```bash
npm install
```

## Compile

```bash
npx hardhat compile
```

## Test

```bash
npx hardhat test
```

## Deploy (localhost)

Start a local node:
```bash
npx hardhat node
```

Deploy contracts:
```bash
npx hardhat run scripts/deploy.js --network localhost
```

## Game Flow

### MultiplierWithScoreGame (Two-Phase)

1. **Phase 1 - playGame()**: Player bets tokens, draws a random multiplier (0.8x, 1.2x, 1.8x, or 3x)
2. **Phase 2 - endGame()**: Player submits score (0-100), final earnings = bet × multiplier × score / 100

### ScratchCardGame (Single-Phase)

1. **playGame()**: Player bets tokens, instantly reveals win/lose result with multiplier

## Multiplier Distribution

| Multiplier | Probability |
|------------|-------------|
| 0.8x | 70% |
| 1.2x | 20% |
| 1.8x | 8% |
| 3.0x | 2% |

## Fee Structure

- **Owner Fee**: 10% of each bet
- **Jackpot Contribution**: 5% of each bet
- **House Funds**: 85% of each bet (for payouts)

## License

MIT
