;; Driver Cooperative - RideHub DAO Governance and Membership Contract
;; Manages driver membership, governance, profit distribution, and cooperative decision-making

;; Error constants
(define-constant ERR-NOT-AUTHORIZED (err u401))
(define-constant ERR-ALREADY-MEMBER (err u402))
(define-constant ERR-NOT-MEMBER (err u403))
(define-constant ERR-INSUFFICIENT-STAKE (err u404))
(define-constant ERR-PROPOSAL-NOT-FOUND (err u405))
(define-constant ERR-VOTING-CLOSED (err u406))
(define-constant ERR-ALREADY-VOTED (err u407))
(define-constant ERR-INVALID-AMOUNT (err u408))
(define-constant ERR-INSUFFICIENT-BALANCE (err u409))
(define-constant ERR-PROPOSAL-NOT-EXECUTED (err u410))

;; System constants
(define-constant CONTRACT-OWNER tx-sender)
(define-constant MEMBERSHIP-STAKE u10000000) ;; 10 STX required for membership
(define-constant VOTING-PERIOD u1008) ;; ~7 days in blocks (assuming 10min blocks)
(define-constant MIN-PROPOSAL-SUPPORT u3) ;; Minimum members to support proposal
(define-constant PLATFORM-FEE-RATE u6) ;; 6% base platform fee (member-adjustable)
(define-constant PROFIT-DISTRIBUTION-RATIO u60) ;; 60% to drivers, 40% to platform

;; Membership tier thresholds
(define-constant TIER-PROBATIONARY u0)
(define-constant TIER-ACTIVE u100)
(define-constant TIER-SENIOR u500)
(define-constant TIER-GUARDIAN u1000)

;; Proposal types
(define-constant PROPOSAL-TYPE-POLICY u1)
(define-constant PROPOSAL-TYPE-ECONOMIC u2)
(define-constant PROPOSAL-TYPE-TECHNICAL u3)
(define-constant PROPOSAL-TYPE-COMMUNITY u4)

;; Data variables
(define-data-var total-members uint u0)
(define-data-var active-members uint u0)
(define-data-var next-proposal-id uint u1)
(define-data-var platform-revenue uint u0)
(define-data-var distributed-profits uint u0)
(define-data-var current-fee-rate uint PLATFORM-FEE-RATE)

;; Member registry with comprehensive information
(define-map members
  { member: principal }
  {
    joined-at: uint,
    stake-amount: uint,
    total-rides: uint,
    reputation-score: uint,
    membership-tier: uint,
    active-status: bool,
    last-activity: uint,
    total-earnings: uint,
    governance-participation: uint
  }
)

;; Governance proposal system
(define-map proposals
  { proposal-id: uint }
  {
    proposer: principal,
    title: (string-ascii 100),
    description: (string-ascii 500),
    proposal-type: uint,
    created-at: uint,
    voting-ends-at: uint,
    votes-for: uint,
    votes-against: uint,
    total-voters: uint,
    executed: bool,
    execution-data: (optional (string-ascii 200))
  }
)

;; Individual voting records
(define-map votes
  { proposal-id: uint, voter: principal }
  {
    vote: bool, ;; true = for, false = against
    voting-power: uint,
    voted-at: uint
  }
)

;; Member profit distribution tracking
(define-map profit-shares
  { member: principal, distribution-round: uint }
  {
    amount: uint,
    claimed: bool,
    distribution-date: uint
  }
)

;; Track distribution rounds
(define-data-var current-distribution-round uint u0)
(define-data-var last-distribution-date uint u0)

;; Member performance metrics
(define-map member-performance
  { member: principal, period: uint }
  {
    rides-completed: uint,
    total-earnings: uint,
    average-rating: uint,
    disputes-resolved: uint,
    governance-votes: uint
  }
)

;; Reputation and feedback system
(define-map reputation-records
  { member: principal, record-id: uint }
  {
    rating: uint, ;; 1-5 scale
    feedback-type: uint, ;; 1=passenger, 2=peer, 3=system
    created-at: uint,
    details: (string-ascii 200)
  }
)

;; Member reputation record counter
(define-map member-reputation-count
  { member: principal }
  { count: uint }
)

;; Public functions

;; Join the driver cooperative as a member
(define-public (join-cooperative (license-number (string-ascii 50)) (vehicle-info (string-ascii 100)))
  (let (
    (current-member (map-get? members { member: tx-sender }))
  )
    ;; Validation checks
    (asserts! (is-none current-member) ERR-ALREADY-MEMBER)
    (asserts! (>= (stx-get-balance tx-sender) MEMBERSHIP-STAKE) ERR-INSUFFICIENT-STAKE)
    
    ;; Transfer membership stake to contract
    (try! (stx-transfer? MEMBERSHIP-STAKE tx-sender (as-contract tx-sender)))
    
    ;; Register new member
    (map-set members
      { member: tx-sender }
      {
        joined-at: stacks-block-height,
        stake-amount: MEMBERSHIP-STAKE,
        total-rides: u0,
        reputation-score: u100, ;; Start with neutral reputation
        membership-tier: TIER-PROBATIONARY,
        active-status: true,
        last-activity: stacks-block-height,
        total-earnings: u0,
        governance-participation: u0
      }
    )
    
    ;; Initialize member performance tracking
    (map-set member-performance
      { member: tx-sender, period: u0 }
      {
        rides-completed: u0,
        total-earnings: u0,
        average-rating: u0,
        disputes-resolved: u0,
        governance-votes: u0
      }
    )
    
    ;; Update member counters
    (var-set total-members (+ (var-get total-members) u1))
    (var-set active-members (+ (var-get active-members) u1))
    
    (ok tx-sender)
  )
)

;; Create governance proposal
(define-public (create-proposal (title (string-ascii 100)) 
                              (description (string-ascii 500)) 
                              (proposal-type uint))
  (let (
    (member-info (unwrap! (map-get? members { member: tx-sender }) ERR-NOT-MEMBER))
    (proposal-id (var-get next-proposal-id))
    (voting-ends (+ stacks-block-height VOTING-PERIOD))
  )
    ;; Only active members can create proposals
    (asserts! (get active-status member-info) ERR-NOT-AUTHORIZED)
    (asserts! (>= (get membership-tier member-info) TIER-ACTIVE) ERR-NOT-AUTHORIZED)
    
    ;; Create proposal
    (map-set proposals
      { proposal-id: proposal-id }
      {
        proposer: tx-sender,
        title: title,
        description: description,
        proposal-type: proposal-type,
        created-at: stacks-block-height,
        voting-ends-at: voting-ends,
        votes-for: u0,
        votes-against: u0,
        total-voters: u0,
        executed: false,
        execution-data: none
      }
    )
    
    ;; Update proposal counter
    (var-set next-proposal-id (+ proposal-id u1))
    
    (ok proposal-id)
  )
)

;; Vote on governance proposal
(define-public (vote-on-proposal (proposal-id uint) (vote-for bool))
  (let (
    (member-info (unwrap! (map-get? members { member: tx-sender }) ERR-NOT-MEMBER))
    (proposal (unwrap! (map-get? proposals { proposal-id: proposal-id }) ERR-PROPOSAL-NOT-FOUND))
    (existing-vote (map-get? votes { proposal-id: proposal-id, voter: tx-sender }))
    (voting-power (calculate-voting-power tx-sender))
  )
    ;; Validation checks
    (asserts! (get active-status member-info) ERR-NOT-AUTHORIZED)
    (asserts! (< stacks-block-height (get voting-ends-at proposal)) ERR-VOTING-CLOSED)
    (asserts! (is-none existing-vote) ERR-ALREADY-VOTED)
    
    ;; Record vote
    (map-set votes
      { proposal-id: proposal-id, voter: tx-sender }
      {
        vote: vote-for,
        voting-power: voting-power,
        voted-at: stacks-block-height
      }
    )
    
    ;; Update proposal vote counts
    (map-set proposals
      { proposal-id: proposal-id }
      (merge proposal {
        votes-for: (if vote-for 
                      (+ (get votes-for proposal) voting-power)
                      (get votes-for proposal)),
        votes-against: (if vote-for
                          (get votes-against proposal)
                          (+ (get votes-against proposal) voting-power)),
        total-voters: (+ (get total-voters proposal) u1)
      })
    )
    
    ;; Update member governance participation
    (map-set members
      { member: tx-sender }
      (merge member-info {
        governance-participation: (+ (get governance-participation member-info) u1)
      })
    )
    
    (ok true)
  )
)

;; Update member ride completion (called by ride management contract)
(define-public (update-member-rides (member principal) (earnings uint) (rating uint))
  (let (
    (member-info (unwrap! (map-get? members { member: member }) ERR-NOT-MEMBER))
    (new-total-rides (+ (get total-rides member-info) u1))
    (new-tier (calculate-membership-tier new-total-rides))
  )
    ;; Only authorized contracts can call this
    (asserts! (is-authorized-caller) ERR-NOT-AUTHORIZED)
    
    ;; Update member statistics
    (map-set members
      { member: member }
      (merge member-info {
        total-rides: new-total-rides,
        membership-tier: new-tier,
        last-activity: stacks-block-height,
        total-earnings: (+ (get total-earnings member-info) earnings)
      })
    )
    
    ;; Update performance metrics
    (update-member-performance member earnings rating)
    
    (ok true)
  )
)

;; Distribute platform profits to members
(define-public (distribute-profits)
  (let (
    (current-revenue (var-get platform-revenue))
    (distribution-amount (/ (* current-revenue PROFIT-DISTRIBUTION-RATIO) u100))
    (distribution-round (+ (var-get current-distribution-round) u1))
  )
    ;; Only contract owner can initiate distribution
    (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-NOT-AUTHORIZED)
    (asserts! (> distribution-amount u0) ERR-INVALID-AMOUNT)
    
    ;; Update distribution tracking
    (var-set current-distribution-round distribution-round)
    (var-set last-distribution-date stacks-block-height)
    (var-set distributed-profits (+ (var-get distributed-profits) distribution-amount))
    
    ;; Calculate and record individual profit shares
    (calculate-member-profit-shares distribution-round distribution-amount)
    
    (ok distribution-amount)
  )
)

;; Claim profit share
(define-public (claim-profit-share (distribution-round uint))
  (let (
    (member-info (unwrap! (map-get? members { member: tx-sender }) ERR-NOT-MEMBER))
    (profit-share (unwrap! (map-get? profit-shares 
                            { member: tx-sender, distribution-round: distribution-round }) 
                           ERR-PROPOSAL-NOT-FOUND))
  )
    ;; Validation checks
    (asserts! (get active-status member-info) ERR-NOT-AUTHORIZED)
    (asserts! (not (get claimed profit-share)) ERR-ALREADY-VOTED)
    (asserts! (> (get amount profit-share) u0) ERR-INVALID-AMOUNT)
    
    ;; Transfer profit share
    (try! (as-contract (stx-transfer? (get amount profit-share) tx-sender tx-sender)))
    
    ;; Mark as claimed
    (map-set profit-shares
      { member: tx-sender, distribution-round: distribution-round }
      (merge profit-share { claimed: true })
    )
    
    (ok (get amount profit-share))
  )
)

;; Private helper functions

;; Calculate voting power based on membership tier and participation
(define-private (calculate-voting-power (member principal))
  (match (map-get? members { member: member })
    member-info (let (
      (base-power u1)
      (tier-multiplier (if (>= (get membership-tier member-info) TIER-GUARDIAN) u3
                          (if (>= (get membership-tier member-info) TIER-SENIOR) u2
                              (if (>= (get membership-tier member-info) TIER-ACTIVE) u1 u1))))
      (participation-bonus (if (> (get governance-participation member-info) u10) u1 u0))
    )
      (+ base-power tier-multiplier participation-bonus)
    )
    u0
  )
)

;; Calculate membership tier based on rides completed
(define-private (calculate-membership-tier (total-rides uint))
  (if (>= total-rides TIER-GUARDIAN) TIER-GUARDIAN
      (if (>= total-rides TIER-SENIOR) TIER-SENIOR
          (if (>= total-rides TIER-ACTIVE) TIER-ACTIVE TIER-PROBATIONARY)))
)

;; Update member performance metrics
(define-private (update-member-performance (member principal) (earnings uint) (rating uint))
  (let (
    (current-performance (default-to
                           { rides-completed: u0, total-earnings: u0, average-rating: u0, 
                             disputes-resolved: u0, governance-votes: u0 }
                           (map-get? member-performance { member: member, period: u0 })))
  )
    (map-set member-performance
      { member: member, period: u0 }
      (merge current-performance {
        rides-completed: (+ (get rides-completed current-performance) u1),
        total-earnings: (+ (get total-earnings current-performance) earnings),
        average-rating: (calculate-average-rating member rating)
      })
    )
  )
)

;; Calculate average rating for member
(define-private (calculate-average-rating (member principal) (new-rating uint))
  (match (map-get? member-performance { member: member, period: u0 })
    performance (let (
      (current-avg (get average-rating performance))
      (total-rides (get rides-completed performance))
    )
      (if (> total-rides u0)
        (/ (+ (* current-avg total-rides) new-rating) (+ total-rides u1))
        new-rating
      )
    )
    new-rating
  )
)

;; Calculate individual profit shares (simplified)
(define-private (calculate-member-profit-shares (distribution-round uint) (total-amount uint))
  (let (
    (active-member-count (var-get active-members))
    (per-member-share (if (> active-member-count u0) 
                        (/ total-amount active-member-count) 
                        u0))
  )
    ;; Simplified: equal distribution to active members
    ;; In practice, this would iterate through members with performance weighting
    per-member-share
  )
)

;; Check if caller is authorized (placeholder for ride management contract)
(define-private (is-authorized-caller)
  (is-eq tx-sender CONTRACT-OWNER) ;; Simplified - would check for specific contract addresses
)

;; Read-only functions

;; Get member information
(define-read-only (get-member-info (member principal))
  (map-get? members { member: member })
)

;; Get proposal information
(define-read-only (get-proposal-info (proposal-id uint))
  (map-get? proposals { proposal-id: proposal-id })
)

;; Get vote information
(define-read-only (get-vote-info (proposal-id uint) (voter principal))
  (map-get? votes { proposal-id: proposal-id, voter: voter })
)

;; Get member performance
(define-read-only (get-member-performance (member principal) (period uint))
  (map-get? member-performance { member: member, period: period })
)

;; Get platform statistics
(define-read-only (get-platform-stats)
  {
    total-members: (var-get total-members),
    active-members: (var-get active-members),
    platform-revenue: (var-get platform-revenue),
    distributed-profits: (var-get distributed-profits),
    current-fee-rate: (var-get current-fee-rate),
    next-proposal-id: (var-get next-proposal-id)
  }
)

;; Check if address is a member
(define-read-only (is-member (address principal))
  (is-some (map-get? members { member: address }))
)

;; Get profit share information
(define-read-only (get-profit-share (member principal) (distribution-round uint))
  (map-get? profit-shares { member: member, distribution-round: distribution-round })
)

