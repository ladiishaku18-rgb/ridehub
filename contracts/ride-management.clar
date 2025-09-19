;; Ride Management - RideHub Trip Processing and Matching Contract
;; Handles ride requests, driver matching, trip execution, and payment processing

;; Error constants
(define-constant ERR-NOT-AUTHORIZED (err u501))
(define-constant ERR-RIDE-NOT-FOUND (err u502))
(define-constant ERR-INVALID-STATUS (err u503))
(define-constant ERR-INSUFFICIENT-PAYMENT (err u504))
(define-constant ERR-DRIVER-NOT-AVAILABLE (err u505))
(define-constant ERR-PASSENGER-NOT-FOUND (err u506))
(define-constant ERR-RIDE-ALREADY-ACCEPTED (err u507))
(define-constant ERR-INVALID-RATING (err u508))
(define-constant ERR-PAYMENT-FAILED (err u509))
(define-constant ERR-DISTANCE-TOO-LONG (err u510))

;; System constants
(define-constant CONTRACT-OWNER tx-sender)
(define-constant BASE-FARE u2000000) ;; 2 STX base fare
(define-constant RATE-PER-KM u500000) ;; 0.5 STX per kilometer
(define-constant MAX-RIDE-DISTANCE u100) ;; 100 km maximum ride distance
(define-constant ESCROW-TIMEOUT u144) ;; ~24 hours in blocks
(define-constant PLATFORM-FEE-RATE u6) ;; 6% platform fee
(define-constant DRIVER-SEARCH-RADIUS u10) ;; 10 km radius for driver matching

;; Ride status constants
(define-constant STATUS-REQUESTED u1)
(define-constant STATUS-ACCEPTED u2)
(define-constant STATUS-IN-PROGRESS u3)
(define-constant STATUS-COMPLETED u4)
(define-constant STATUS-CANCELLED u5)
(define-constant STATUS-DISPUTED u6)

;; Driver availability status
(define-constant DRIVER-AVAILABLE u1)
(define-constant DRIVER-BUSY u2)
(define-constant DRIVER-OFFLINE u3)

;; Data variables
(define-data-var next-ride-id uint u1)
(define-data-var total-rides uint u0)
(define-data-var completed-rides uint u0)
(define-data-var total-revenue uint u0)
(define-data-var total-distance uint u0)

;; Ride request and management system
(define-map rides
  { ride-id: uint }
  {
    passenger: principal,
    driver: (optional principal),
    pickup-location: (string-ascii 100),
    destination: (string-ascii 100),
    estimated-distance: uint,
    fare-amount: uint,
    platform-fee: uint,
    driver-payout: uint,
    status: uint,
    requested-at: uint,
    accepted-at: (optional uint),
    completed-at: (optional uint),
    passenger-rating: (optional uint),
    driver-rating: (optional uint),
    notes: (optional (string-ascii 200))
  }
)

;; Driver availability and location tracking
(define-map driver-status
  { driver: principal }
  {
    availability: uint,
    current-location: (string-ascii 50),
    last-updated: uint,
    current-ride: (optional uint),
    total-rides-today: uint,
    earnings-today: uint,
    online-since: uint
  }
)

;; Passenger profiles and ride history
(define-map passengers
  { passenger: principal }
  {
    total-rides: uint,
    average-rating: uint,
    total-spent: uint,
    account-balance: uint,
    last-ride: (optional uint),
    verified: bool,
    created-at: uint
  }
)

;; Payment escrow system
(define-map ride-escrow
  { ride-id: uint }
  {
    amount: uint,
    deposited-at: uint,
    released: bool,
    release-to: (optional principal)
  }
)

;; Rating and feedback system
(define-map ride-ratings
  { ride-id: uint, rater: principal }
  {
    rating: uint,
    feedback: (string-ascii 200),
    rated-at: uint,
    rating-type: uint ;; 1=passenger-to-driver, 2=driver-to-passenger
  }
)

;; Geographic coverage areas
(define-map service-areas
  { area-id: uint }
  {
    name: (string-ascii 50),
    coordinates: (string-ascii 100),
    active-drivers: uint,
    base-fare-multiplier: uint,
    surge-pricing-active: bool,
    surge-multiplier: uint
  }
)

;; Driver earnings tracking
(define-map driver-earnings
  { driver: principal, period: uint }
  {
    total-rides: uint,
    total-earnings: uint,
    average-rating: uint,
    tips-received: uint,
    platform-fees-paid: uint
  }
)

;; Ride matching queue
(define-map ride-queue
  { queue-position: uint }
  {
    ride-id: uint,
    priority-score: uint,
    queued-at: uint
  }
)

;; Public functions

;; Register as a passenger
(define-public (register-passenger)
  (let (
    (existing-passenger (map-get? passengers { passenger: tx-sender }))
  )
    (asserts! (is-none existing-passenger) ERR-NOT-AUTHORIZED)
    
    (map-set passengers
      { passenger: tx-sender }
      {
        total-rides: u0,
        average-rating: u5, ;; Start with perfect rating
        total-spent: u0,
        account-balance: u0,
        last-ride: none,
        verified: false,
        created-at: stacks-block-height
      }
    )
    
    (ok tx-sender)
  )
)

;; Set driver availability status
(define-public (set-driver-availability (availability uint) (current-location (string-ascii 50)))
  (let (
    (current-status (map-get? driver-status { driver: tx-sender }))
  )
    ;; Validate driver is a cooperative member (simplified check)
    (asserts! (is-cooperative-member tx-sender) ERR-NOT-AUTHORIZED)
    (asserts! (and (>= availability DRIVER-AVAILABLE) (<= availability DRIVER-OFFLINE)) ERR-INVALID-STATUS)
    
    (map-set driver-status
      { driver: tx-sender }
      (merge (default-to
               { availability: DRIVER-OFFLINE, current-location: "", last-updated: u0,
                 current-ride: none, total-rides-today: u0, earnings-today: u0, online-since: u0 }
               current-status) {
        availability: availability,
        current-location: current-location,
        last-updated: stacks-block-height,
        online-since: (if (is-eq availability DRIVER-AVAILABLE) 
                         stacks-block-height 
                         (get online-since (default-to 
                           { availability: u0, current-location: "", last-updated: u0,
                             current-ride: none, total-rides-today: u0, earnings-today: u0, online-since: u0 } 
                           current-status)))
      })
    )
    
    (ok true)
  )
)

;; Request a ride
(define-public (request-ride (pickup-location (string-ascii 100)) 
                           (destination (string-ascii 100)) 
                           (estimated-distance uint))
  (let (
    (ride-id (var-get next-ride-id))
    (fare-calculation (calculate-fare estimated-distance))
    (total-cost (+ (get fare fare-calculation) (get platform-fee fare-calculation)))
    (passenger-info (unwrap! (map-get? passengers { passenger: tx-sender }) ERR-PASSENGER-NOT-FOUND))
  )
    ;; Validation checks
    (asserts! (<= estimated-distance MAX-RIDE-DISTANCE) ERR-DISTANCE-TOO-LONG)
    (asserts! (>= (stx-get-balance tx-sender) total-cost) ERR-INSUFFICIENT-PAYMENT)
    
    ;; Transfer payment to escrow
    (try! (stx-transfer? total-cost tx-sender (as-contract tx-sender)))
    
    ;; Create ride record
    (map-set rides
      { ride-id: ride-id }
      {
        passenger: tx-sender,
        driver: none,
        pickup-location: pickup-location,
        destination: destination,
        estimated-distance: estimated-distance,
        fare-amount: (get fare fare-calculation),
        platform-fee: (get platform-fee fare-calculation),
        driver-payout: (get driver-payout fare-calculation),
        status: STATUS-REQUESTED,
        requested-at: stacks-block-height,
        accepted-at: none,
        completed-at: none,
        passenger-rating: none,
        driver-rating: none,
        notes: none
      }
    )
    
    ;; Set up payment escrow
    (map-set ride-escrow
      { ride-id: ride-id }
      {
        amount: total-cost,
        deposited-at: stacks-block-height,
        released: false,
        release-to: none
      }
    )
    
    ;; Update system counters
    (var-set next-ride-id (+ ride-id u1))
    (var-set total-rides (+ (var-get total-rides) u1))
    
    ;; Update passenger statistics
    (map-set passengers
      { passenger: tx-sender }
      (merge passenger-info {
        last-ride: (some ride-id)
      })
    )
    
    ;; Trigger driver matching (simplified)
    (match-available-driver ride-id pickup-location)
    
    (ok ride-id)
  )
)

;; Accept a ride as a driver
(define-public (accept-ride (ride-id uint))
  (let (
    (ride-info (unwrap! (map-get? rides { ride-id: ride-id }) ERR-RIDE-NOT-FOUND))
    (driver-info (unwrap! (map-get? driver-status { driver: tx-sender }) ERR-DRIVER-NOT-AVAILABLE))
  )
    ;; Validation checks
    (asserts! (is-cooperative-member tx-sender) ERR-NOT-AUTHORIZED)
    (asserts! (is-eq (get status ride-info) STATUS-REQUESTED) ERR-RIDE-ALREADY-ACCEPTED)
    (asserts! (is-eq (get availability driver-info) DRIVER-AVAILABLE) ERR-DRIVER-NOT-AVAILABLE)
    (asserts! (is-none (get driver ride-info)) ERR-RIDE-ALREADY-ACCEPTED)
    
    ;; Update ride status
    (map-set rides
      { ride-id: ride-id }
      (merge ride-info {
        driver: (some tx-sender),
        status: STATUS-ACCEPTED,
        accepted-at: (some stacks-block-height)
      })
    )
    
    ;; Update driver status
    (map-set driver-status
      { driver: tx-sender }
      (merge driver-info {
        availability: DRIVER-BUSY,
        current-ride: (some ride-id),
        last-updated: stacks-block-height
      })
    )
    
    (ok true)
  )
)

;; Start the ride trip
(define-public (start-ride (ride-id uint))
  (let (
    (ride-info (unwrap! (map-get? rides { ride-id: ride-id }) ERR-RIDE-NOT-FOUND))
  )
    ;; Validation checks
    (asserts! (is-eq (some tx-sender) (get driver ride-info)) ERR-NOT-AUTHORIZED)
    (asserts! (is-eq (get status ride-info) STATUS-ACCEPTED) ERR-INVALID-STATUS)
    
    ;; Update ride status
    (map-set rides
      { ride-id: ride-id }
      (merge ride-info {
        status: STATUS-IN-PROGRESS
      })
    )
    
    (ok true)
  )
)

;; Complete the ride
(define-public (complete-ride (ride-id uint) (actual-distance uint))
  (let (
    (ride-info (unwrap! (map-get? rides { ride-id: ride-id }) ERR-RIDE-NOT-FOUND))
    (driver-info (unwrap! (map-get? driver-status { driver: tx-sender }) ERR-DRIVER-NOT-AVAILABLE))
    (escrow-info (unwrap! (map-get? ride-escrow { ride-id: ride-id }) ERR-RIDE-NOT-FOUND))
  )
    ;; Validation checks
    (asserts! (is-eq (some tx-sender) (get driver ride-info)) ERR-NOT-AUTHORIZED)
    (asserts! (is-eq (get status ride-info) STATUS-IN-PROGRESS) ERR-INVALID-STATUS)
    (asserts! (not (get released escrow-info)) ERR-PAYMENT-FAILED)
    
    ;; Update ride status
    (map-set rides
      { ride-id: ride-id }
      (merge ride-info {
        status: STATUS-COMPLETED,
        completed-at: (some stacks-block-height)
      })
    )
    
    ;; Release payment to driver
    (try! (as-contract (stx-transfer? (get driver-payout ride-info) tx-sender (unwrap-panic (get driver ride-info)))))
    
    ;; Update escrow status
    (map-set ride-escrow
      { ride-id: ride-id }
      (merge escrow-info {
        released: true,
        release-to: (get driver ride-info)
      })
    )
    
    ;; Update driver status
    (map-set driver-status
      { driver: tx-sender }
      (merge driver-info {
        availability: DRIVER-AVAILABLE,
        current-ride: none,
        total-rides-today: (+ (get total-rides-today driver-info) u1),
        earnings-today: (+ (get earnings-today driver-info) (get driver-payout ride-info))
      })
    )
    
    ;; Update system statistics
    (var-set completed-rides (+ (var-get completed-rides) u1))
    (var-set total-revenue (+ (var-get total-revenue) (get platform-fee ride-info)))
    (var-set total-distance (+ (var-get total-distance) actual-distance))
    
    ;; Update cooperative member stats (would call cooperative contract)
    (update-cooperative-member-stats tx-sender (get driver-payout ride-info))
    
    (ok true)
  )
)

;; Rate the ride experience
(define-public (rate-ride (ride-id uint) (rating uint) (feedback (string-ascii 200)))
  (let (
    (ride-info (unwrap! (map-get? rides { ride-id: ride-id }) ERR-RIDE-NOT-FOUND))
    (is-passenger (is-eq tx-sender (get passenger ride-info)))
    (is-driver (is-eq (some tx-sender) (get driver ride-info)))
  )
    ;; Validation checks
    (asserts! (or is-passenger is-driver) ERR-NOT-AUTHORIZED)
    (asserts! (is-eq (get status ride-info) STATUS-COMPLETED) ERR-INVALID-STATUS)
    (asserts! (and (>= rating u1) (<= rating u5)) ERR-INVALID-RATING)
    
    ;; Record rating
    (map-set ride-ratings
      { ride-id: ride-id, rater: tx-sender }
      {
        rating: rating,
        feedback: feedback,
        rated-at: stacks-block-height,
        rating-type: (if is-passenger u1 u2)
      }
    )
    
    ;; Update ride with rating
    (map-set rides
      { ride-id: ride-id }
      (merge ride-info {
        passenger-rating: (if is-passenger (some rating) (get passenger-rating ride-info)),
        driver-rating: (if is-driver (some rating) (get driver-rating ride-info))
      })
    )
    
    (ok true)
  )
)

;; Add funds to passenger account
(define-public (add-passenger-funds (amount uint))
  (let (
    (passenger-info (unwrap! (map-get? passengers { passenger: tx-sender }) ERR-PASSENGER-NOT-FOUND))
  )
    ;; Transfer STX to contract
    (try! (stx-transfer? amount tx-sender (as-contract tx-sender)))
    
    ;; Update passenger balance
    (map-set passengers
      { passenger: tx-sender }
      (merge passenger-info {
        account-balance: (+ (get account-balance passenger-info) amount)
      })
    )
    
    (ok amount)
  )
)

;; Private helper functions

;; Calculate fare based on distance
(define-private (calculate-fare (distance uint))
  (let (
    (base-fare BASE-FARE)
    (distance-fare (* distance RATE-PER-KM))
    (total-fare (+ base-fare distance-fare))
    (platform-fee (/ (* total-fare PLATFORM-FEE-RATE) u100))
  )
    {
      fare: total-fare,
      platform-fee: platform-fee,
      driver-payout: (- total-fare platform-fee)
    }
  )
)

;; Match available driver (simplified)
(define-private (match-available-driver (ride-id uint) (pickup-location (string-ascii 100)))
  ;; Simplified matching - in practice would use geographic proximity
  true
)

;; Check if address is a cooperative member (placeholder)
(define-private (is-cooperative-member (address principal))
  true ;; Simplified - would check with cooperative contract
)

;; Update cooperative member statistics (placeholder)
(define-private (update-cooperative-member-stats (member principal) (earnings uint))
  true ;; Simplified - would call cooperative contract
)

;; Read-only functions

;; Get ride information
(define-read-only (get-ride-info (ride-id uint))
  (map-get? rides { ride-id: ride-id })
)

;; Get driver status
(define-read-only (get-driver-status (driver principal))
  (map-get? driver-status { driver: driver })
)

;; Get passenger information
(define-read-only (get-passenger-info (passenger principal))
  (map-get? passengers { passenger: passenger })
)

;; Get ride rating
(define-read-only (get-ride-rating (ride-id uint) (rater principal))
  (map-get? ride-ratings { ride-id: ride-id, rater: rater })
)

;; Get platform statistics
(define-read-only (get-platform-statistics)
  {
    total-rides: (var-get total-rides),
    completed-rides: (var-get completed-rides),
    total-revenue: (var-get total-revenue),
    total-distance: (var-get total-distance),
    next-ride-id: (var-get next-ride-id)
  }
)

;; Calculate estimated fare
(define-read-only (estimate-fare (distance uint))
  (calculate-fare distance)
)

;; Get escrow information
(define-read-only (get-escrow-info (ride-id uint))
  (map-get? ride-escrow { ride-id: ride-id })
)

;; Get driver earnings for period
(define-read-only (get-driver-earnings (driver principal) (period uint))
  (map-get? driver-earnings { driver: driver, period: period })
)

