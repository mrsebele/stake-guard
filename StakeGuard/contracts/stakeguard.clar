;; Stake Guard - Production-Ready Validator Staking System with Slashing
;; Advanced staking with delegation, rewards, and penalty mechanisms

;; Constants
(define-constant contract-owner tx-sender)
(define-constant err-unauthorized (err u100))
(define-constant err-invalid-amount (err u101))
(define-constant err-insufficient-stake (err u102))
(define-constant err-validator-exists (err u103))
(define-constant err-validator-not-found (err u104))
(define-constant err-already-delegated (err u105))
(define-constant err-not-delegated (err u106))
(define-constant err-cooldown-active (err u107))
(define-constant err-below-minimum (err u108))
(define-constant err-exceeds-maximum (err u109))
(define-constant err-paused (err u110))
(define-constant err-invalid-percentage (err u111))
(define-constant err-validator-jailed (err u112))

;; Data Variables
(define-data-var min-validator-stake uint u50000000000) ;; 50,000 STX
(define-data-var min-delegation uint u1000000000) ;; 1,000 STX
(define-data-var max-validators uint u100)
(define-data-var unbonding-period uint u2016) ;; ~14 days in blocks
(define-data-var commission-rate uint u1000) ;; 10% max validator commission
(define-data-var slash-percentage uint u500) ;; 5% slash for misbehavior
(define-data-var reward-rate uint u100) ;; 1% per cycle base rate
(define-data-var total-staked uint u0)
(define-data-var active-validators uint u0)
(define-data-var is-paused bool false)
(define-data-var treasury principal contract-owner)
(define-data-var last-reward-block uint burn-block-height)
(define-data-var reward-per-block uint u1000) ;; Rewards per block

;; Data Maps
(define-map validators principal {
  stake: uint,
  total-delegated: uint,
  commission: uint,
  rewards-earned: uint,
  created-at: uint,
  jailed: bool,
  jail-end-block: uint,
  slash-count: uint
})

(define-map delegations {delegator: principal, validator: principal} {
  amount: uint,
  rewards-earned: uint,
  delegated-at: uint
})

(define-map unbonding-queue {owner: principal, id: uint} {
  amount: uint,
  unlock-block: uint,
  is-validator: bool
})

(define-map delegation-history principal (list 100 {
  validator: principal,
  amount: uint,
  block: uint,
  action: (string-ascii 10)
}))

(define-map validator-performance principal {
  blocks-validated: uint,
  blocks-missed: uint,
  uptime-percentage: uint
})

(define-data-var unbonding-id-nonce uint u0)

;; Read-only functions
(define-read-only (get-validator-info (validator principal))
  (map-get? validators validator)
)

(define-read-only (get-delegation (delegator principal) (validator principal))
  (map-get? delegations {delegator: delegator, validator: validator})
)

(define-read-only (get-total-staked)
  (var-get total-staked)
)

(define-read-only (get-validator-stake (validator principal))
  (match (map-get? validators validator)
    validator-info (+ (get stake validator-info) (get total-delegated validator-info))
    u0
  )
)

(define-read-only (calculate-rewards (delegator principal) (validator principal))
  (match (map-get? delegations {delegator: delegator, validator: validator})
    delegation
    (let ((blocks-elapsed (- burn-block-height (get delegated-at delegation)))
          (base-reward (/ (* (get amount delegation) (var-get reward-per-block) blocks-elapsed) u100000000)))
      (match (map-get? validators validator)
        validator-info
        (let ((commission (get commission validator-info))
              (validator-cut (/ (* base-reward commission) u10000)))
          (- base-reward validator-cut)
        )
        u0
      )
    )
    u0
  )
)

(define-read-only (is-validator (address principal))
  (is-some (map-get? validators address))
)

(define-read-only (get-staking-stats)
  {
    total-staked: (var-get total-staked),
    active-validators: (var-get active-validators),
    min-validator-stake: (var-get min-validator-stake),
    min-delegation: (var-get min-delegation),
    reward-rate: (var-get reward-rate),
    unbonding-period: (var-get unbonding-period)
  }
)

;; Private functions
(define-private (add-to-history (user principal) (validator principal) (amount uint) (action (string-ascii 10)))
  (let ((current-history (default-to (list) (map-get? delegation-history user))))
    (map-set delegation-history user
      (unwrap! (as-max-len? (append current-history {
        validator: validator,
        amount: amount,
        block: burn-block-height,
        action: action
      }) u100) false))
    true
  )
)

(define-private (distribute-rewards)
  (let ((blocks-elapsed (- burn-block-height (var-get last-reward-block))))
    (if (> blocks-elapsed u0)
      (begin
        (var-set last-reward-block burn-block-height)
        true
      )
      false
    )
  )
)

;; Public functions
(define-public (register-validator (stake-amount uint) (commission uint))
  (begin
    (asserts! (not (var-get is-paused)) err-paused)
    (asserts! (>= stake-amount (var-get min-validator-stake)) err-below-minimum)
    (asserts! (<= commission (var-get commission-rate)) err-invalid-percentage)
    (asserts! (is-none (map-get? validators tx-sender)) err-validator-exists)
    (asserts! (< (var-get active-validators) (var-get max-validators)) err-exceeds-maximum)
    
    ;; Transfer stake
    (try! (stx-transfer? stake-amount tx-sender (as-contract tx-sender)))
    
    ;; Register validator
    (map-set validators tx-sender {
      stake: stake-amount,
      total-delegated: u0,
      commission: commission,
      rewards-earned: u0,
      created-at: burn-block-height,
      jailed: false,
      jail-end-block: u0,
      slash-count: u0
    })
    
    ;; Initialize performance
    (map-set validator-performance tx-sender {
      blocks-validated: u0,
      blocks-missed: u0,
      uptime-percentage: u10000 ;; 100%
    })
    
    ;; Update global state
    (var-set total-staked (+ (var-get total-staked) stake-amount))
    (var-set active-validators (+ (var-get active-validators) u1))
    
    (ok stake-amount)
  )
)

(define-public (delegate (validator principal) (amount uint))
  (begin
    (asserts! (not (var-get is-paused)) err-paused)
    (asserts! (>= amount (var-get min-delegation)) err-below-minimum)
    (asserts! (is-validator validator) err-validator-not-found)
    
    ;; Check validator not jailed
    (match (map-get? validators validator)
      validator-info (asserts! (not (get jailed validator-info)) err-validator-jailed)
      true
    )
    
    ;; Check not already delegated to this validator
    (asserts! (is-none (map-get? delegations {delegator: tx-sender, validator: validator})) err-already-delegated)
    
    ;; Transfer delegation
    (try! (stx-transfer? amount tx-sender (as-contract tx-sender)))
    
    ;; Create delegation
    (map-set delegations {delegator: tx-sender, validator: validator} {
      amount: amount,
      rewards-earned: u0,
      delegated-at: burn-block-height
    })
    
    ;; Update validator info
    (match (map-get? validators validator)
      validator-info
      (map-set validators validator 
        (merge validator-info {
          total-delegated: (+ (get total-delegated validator-info) amount)
        }))
      true
    )
    
    ;; Update global state
    (var-set total-staked (+ (var-get total-staked) amount))
    
    ;; Add to history
    (add-to-history tx-sender validator amount "delegate")
    
    (ok amount)
  )
)

(define-public (undelegate (validator principal) (amount uint))
  (let ((delegation-key {delegator: tx-sender, validator: validator}))
    (match (map-get? delegations delegation-key)
      delegation
      (let ((delegation-amount (get amount delegation))
            (rewards (calculate-rewards tx-sender validator))
            (unbonding-id (var-get unbonding-id-nonce)))
        
        (asserts! (not (var-get is-paused)) err-paused)
        (asserts! (>= delegation-amount amount) err-insufficient-stake)
        
        ;; Claim rewards first
        (if (> rewards u0)
          (try! (as-contract (stx-transfer? rewards tx-sender tx-sender)))
          true
        )
        
        ;; Update or remove delegation
        (if (is-eq delegation-amount amount)
          (map-delete delegations delegation-key)
          (map-set delegations delegation-key
            (merge delegation {amount: (- delegation-amount amount)}))
        )
        
        ;; Update validator info
        (match (map-get? validators validator)
          validator-info
          (map-set validators validator
            (merge validator-info {
              total-delegated: (- (get total-delegated validator-info) amount)
            }))
          true
        )
        
        ;; Add to unbonding queue
        (map-set unbonding-queue {owner: tx-sender, id: unbonding-id} {
          amount: amount,
          unlock-block: (+ burn-block-height (var-get unbonding-period)),
          is-validator: false
        })
        
        ;; Update nonce
        (var-set unbonding-id-nonce (+ unbonding-id u1))
        
        ;; Update global state
        (var-set total-staked (- (var-get total-staked) amount))
        
        ;; Add to history
        (add-to-history tx-sender validator amount "undelegate")
        
        (ok {amount: amount, unbonding-id: unbonding-id, unlock-block: (+ burn-block-height (var-get unbonding-period))})
      )
      err-not-delegated
    )
  )
)

(define-public (claim-unbonded (unbonding-id uint))
  (let ((unbonding-key {owner: tx-sender, id: unbonding-id}))
    (match (map-get? unbonding-queue unbonding-key)
      unbonding-info
      (begin
        (asserts! (>= burn-block-height (get unlock-block unbonding-info)) err-cooldown-active)
        
        ;; Transfer unbonded amount
        (try! (as-contract (stx-transfer? (get amount unbonding-info) tx-sender tx-sender)))
        
        ;; Remove from queue
        (map-delete unbonding-queue unbonding-key)
        
        (ok (get amount unbonding-info))
      )
      err-not-delegated
    )
  )
)

(define-public (claim-rewards (validator principal))
  (let ((rewards (calculate-rewards tx-sender validator)))
    (asserts! (> rewards u0) err-invalid-amount)
    
    ;; Transfer rewards
    (try! (as-contract (stx-transfer? rewards tx-sender tx-sender)))
    
    ;; Update delegation
    (match (map-get? delegations {delegator: tx-sender, validator: validator})
      delegation
      (map-set delegations {delegator: tx-sender, validator: validator}
        (merge delegation {
          rewards-earned: (+ (get rewards-earned delegation) rewards),
          delegated-at: burn-block-height
        }))
      true
    )
    
    (ok rewards)
  )
)

(define-public (slash-validator (validator principal) (reason (string-ascii 50)))
  (begin
    (asserts! (is-eq tx-sender contract-owner) err-unauthorized)
    
    (match (map-get? validators validator)
      validator-info
      (let ((total-stake (+ (get stake validator-info) (get total-delegated validator-info)))
            (slash-amount (/ (* total-stake (var-get slash-percentage)) u10000))
            (new-slash-count (+ (get slash-count validator-info) u1)))
        
        ;; Update validator info
        (map-set validators validator
          (merge validator-info {
            stake: (- (get stake validator-info) (/ (* (get stake validator-info) (var-get slash-percentage)) u10000)),
            total-delegated: (- (get total-delegated validator-info) (/ (* (get total-delegated validator-info) (var-get slash-percentage)) u10000)),
            jailed: (>= new-slash-count u3),
            jail-end-block: (if (>= new-slash-count u3) (+ burn-block-height u8640) u0), ;; ~60 days
            slash-count: new-slash-count
          }))
        
        ;; Transfer slashed amount to treasury
        (try! (as-contract (stx-transfer? slash-amount tx-sender (var-get treasury))))
        
        ;; Update global state
        (var-set total-staked (- (var-get total-staked) slash-amount))
        
        (ok {slashed: slash-amount, reason: reason})
      )
      err-validator-not-found
    )
  )
)

(define-public (unjail-validator)
  (match (map-get? validators tx-sender)
    validator-info
    (begin
      (asserts! (get jailed validator-info) err-unauthorized)
      (asserts! (>= burn-block-height (get jail-end-block validator-info)) err-cooldown-active)
      
      ;; Unjail validator
      (map-set validators tx-sender
        (merge validator-info {
          jailed: false,
          jail-end-block: u0
        }))
      
      (ok true)
    )
    err-validator-not-found
  )
)

;; Admin functions
(define-public (set-parameters (min-stake uint) (min-del uint) (unbonding uint) (slash uint))
  (begin
    (asserts! (is-eq tx-sender contract-owner) err-unauthorized)
    (var-set min-validator-stake min-stake)
    (var-set min-delegation min-del)
    (var-set unbonding-period unbonding)
    (var-set slash-percentage slash)
    (ok true)
  )
)

(define-public (set-paused (paused bool))
  (begin
    (asserts! (is-eq tx-sender contract-owner) err-unauthorized)
    (var-set is-paused paused)
    (ok paused)
  )
)

(define-public (set-treasury (new-treasury principal))
  (begin
    (asserts! (is-eq tx-sender contract-owner) err-unauthorized)
    (var-set treasury new-treasury)
    (ok new-treasury)
  )
)