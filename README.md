# Stake Guard - Validator Staking System

Advanced staking protocol with delegation, slashing mechanics, and automated rewards distribution.

## Core Features
- **Validator Registration**: Stake 50,000+ STX to become a validator
- **Delegation**: Delegate 1,000+ STX to earn rewards
- **Slashing**: Penalty mechanism for misbehaving validators
- **Unbonding**: 14-day cooldown for withdrawals
- **Jailing**: Auto-jail after 3 slashing events

## Quick Usage

### Become Validator
```clarity
(contract-call? .stakeguard register-validator u50000000000 u500) ;; 50k STX, 5% commission
```

### Delegate to Validator
```clarity
(contract-call? .stakeguard delegate 'SP_VALIDATOR u1000000000) ;; 1k STX
```

### Claim Rewards
```clarity
(contract-call? .stakeguard claim-rewards 'SP_VALIDATOR)
```

### Undelegate
```clarity
(contract-call? .stakeguard undelegate 'SP_VALIDATOR u1000000000)
;; Returns: {amount: u1000000000, unbonding-id: u0, unlock-block: u12345}
```

### Claim After Unbonding
```clarity
(contract-call? .stakeguard claim-unbonded u0) ;; Use unbonding-id
```

## Key Parameters
- Min Validator Stake: 50,000 STX
- Min Delegation: 1,000 STX  
- Unbonding Period: ~14 days
- Max Commission: 10%
- Slash Rate: 5%
- Jail Duration: ~60 days after 3 slashes

## Security
- Slashing protection for network security
- Unbonding period prevents bank runs
- Jailing system for repeat offenders
- Commission caps protect delegators
