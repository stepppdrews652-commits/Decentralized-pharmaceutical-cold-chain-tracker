;; Cold Chain Monitor Smart Contract
;; Monitors temperature-sensitive pharmaceutical shipments across supply chain
;; Records temperature data, validates compliance, triggers alerts, and manages insurance claims

;; Error codes
(define-constant ERR-NOT-AUTHORIZED (err u100))
(define-constant ERR-SHIPMENT-EXISTS (err u101))
(define-constant ERR-SHIPMENT-NOT-FOUND (err u102))
(define-constant ERR-INVALID-TEMPERATURE (err u103))
(define-constant ERR-INVALID-THRESHOLD (err u104))
(define-constant ERR-CLAIM-EXISTS (err u105))
(define-constant ERR-CLAIM-NOT-FOUND (err u106))
(define-constant ERR-SHIPMENT-NOT-VIOLATED (err u107))
(define-constant ERR-ALREADY-SETTLED (err u108))

;; Data variables
(define-data-var contract-owner principal tx-sender)
(define-data-var shipment-nonce uint u0)
(define-data-var claim-nonce uint u0)

;; Shipment status constants
(define-constant STATUS-ACTIVE u1)
(define-constant STATUS-COMPLETED u2)
(define-constant STATUS-VIOLATED u3)
(define-constant STATUS-CLAIMED u4)

;; Claim status constants
(define-constant CLAIM-PENDING u1)
(define-constant CLAIM-APPROVED u2)
(define-constant CLAIM-REJECTED u3)
(define-constant CLAIM-SETTLED u4)

;; Data maps
(define-map shipments
    uint
    {
        owner: principal,
        product-name: (string-ascii 100),
        origin: (string-ascii 100),
        destination: (string-ascii 100),
        min-temp: int,
        max-temp: int,
        status: uint,
        created-at: uint,
        completed-at: (optional uint),
        violation-count: uint,
        insured: bool,
        insurance-amount: uint
    }
)

(define-map temperature-readings
    { shipment-id: uint, reading-id: uint }
    {
        temperature: int,
        timestamp: uint,
        sensor-id: (string-ascii 50),
        location: (string-ascii 100),
        recorded-by: principal
    }
)

(define-map reading-counts
    uint
    uint
)

(define-map violations
    { shipment-id: uint, violation-id: uint }
    {
        temperature: int,
        timestamp: uint,
        severity: uint,
        reported-by: principal
    }
)

(define-map violation-counts
    uint
    uint
)

(define-map insurance-claims
    uint
    {
        shipment-id: uint,
        claimant: principal,
        amount: uint,
        status: uint,
        filed-at: uint,
        settled-at: (optional uint),
        evidence-hash: (string-ascii 64)
    }
)

(define-map authorized-sensors
    principal
    bool
)

;; Private functions
(define-private (is-contract-owner)
    (is-eq tx-sender (var-get contract-owner))
)

(define-private (is-shipment-owner (shipment-id uint))
    (match (map-get? shipments shipment-id)
        shipment (is-eq tx-sender (get owner shipment))
        false
    )
)

(define-private (is-authorized-sensor)
    (default-to false (map-get? authorized-sensors tx-sender))
)

(define-private (get-reading-count (shipment-id uint))
    (default-to u0 (map-get? reading-counts shipment-id))
)

(define-private (get-violation-count (shipment-id uint))
    (default-to u0 (map-get? violation-counts shipment-id))
)

;; Public functions

;; Initialize contract and authorize sensors
(define-public (authorize-sensor (sensor principal))
    (begin
        (asserts! (is-contract-owner) ERR-NOT-AUTHORIZED)
        (ok (map-set authorized-sensors sensor true))
    )
)

(define-public (revoke-sensor (sensor principal))
    (begin
        (asserts! (is-contract-owner) ERR-NOT-AUTHORIZED)
        (ok (map-delete authorized-sensors sensor))
    )
)

;; Create a new shipment
(define-public (create-shipment 
    (product-name (string-ascii 100))
    (origin (string-ascii 100))
    (destination (string-ascii 100))
    (min-temp int)
    (max-temp int)
    (insured bool)
    (insurance-amount uint))
    (let
        (
            (shipment-id (var-get shipment-nonce))
        )
        (asserts! (< min-temp max-temp) ERR-INVALID-THRESHOLD)
        (map-set shipments shipment-id {
            owner: tx-sender,
            product-name: product-name,
            origin: origin,
            destination: destination,
            min-temp: min-temp,
            max-temp: max-temp,
            status: STATUS-ACTIVE,
            created-at: stacks-block-height,
            completed-at: none,
            violation-count: u0,
            insured: insured,
            insurance-amount: insurance-amount
        })
        (var-set shipment-nonce (+ shipment-id u1))
        (ok shipment-id)
    )
)

;; Record temperature reading
(define-public (record-temperature 
    (shipment-id uint)
    (temperature int)
    (sensor-id (string-ascii 50))
    (location (string-ascii 100)))
    (let
        (
            (reading-count (get-reading-count shipment-id))
            (shipment (unwrap! (map-get? shipments shipment-id) ERR-SHIPMENT-NOT-FOUND))
        )
        (asserts! (is-authorized-sensor) ERR-NOT-AUTHORIZED)
        (asserts! (is-eq (get status shipment) STATUS-ACTIVE) ERR-NOT-AUTHORIZED)
        
        ;; Store temperature reading
        (map-set temperature-readings 
            { shipment-id: shipment-id, reading-id: reading-count }
            {
                temperature: temperature,
                timestamp: stacks-block-height,
                sensor-id: sensor-id,
                location: location,
                recorded-by: tx-sender
            }
        )
        (map-set reading-counts shipment-id (+ reading-count u1))
        
        ;; Check for violations
        (if (or (< temperature (get min-temp shipment)) (> temperature (get max-temp shipment)))
            (begin
                (try! (record-violation shipment-id temperature))
                (ok true)
            )
            (ok false)
        )
    )
)

;; Record temperature violation
(define-private (record-violation (shipment-id uint) (temperature int))
    (let
        (
            (violation-count (get-violation-count shipment-id))
            (shipment (unwrap! (map-get? shipments shipment-id) ERR-SHIPMENT-NOT-FOUND))
            (severity (if (or (< temperature (- (get min-temp shipment) 5)) 
                             (> temperature (+ (get max-temp shipment) 5)))
                         u3  ;; Critical
                         u1  ;; Minor
                     ))
        )
        (map-set violations
            { shipment-id: shipment-id, violation-id: violation-count }
            {
                temperature: temperature,
                timestamp: stacks-block-height,
                severity: severity,
                reported-by: tx-sender
            }
        )
        (map-set violation-counts shipment-id (+ violation-count u1))
        
        ;; Update shipment status
        (map-set shipments shipment-id 
            (merge shipment { 
                status: STATUS-VIOLATED,
                violation-count: (+ (get violation-count shipment) u1)
            })
        )
        (ok true)
    )
)

;; Complete shipment
(define-public (complete-shipment (shipment-id uint))
    (let
        (
            (shipment (unwrap! (map-get? shipments shipment-id) ERR-SHIPMENT-NOT-FOUND))
        )
        (asserts! (is-shipment-owner shipment-id) ERR-NOT-AUTHORIZED)
        (asserts! (is-eq (get status shipment) STATUS-ACTIVE) ERR-NOT-AUTHORIZED)
        
        (ok (map-set shipments shipment-id 
            (merge shipment { 
                status: STATUS-COMPLETED,
                completed-at: (some stacks-block-height)
            })
        ))
    )
)

;; File insurance claim
(define-public (file-insurance-claim 
    (shipment-id uint)
    (amount uint)
    (evidence-hash (string-ascii 64)))
    (let
        (
            (shipment (unwrap! (map-get? shipments shipment-id) ERR-SHIPMENT-NOT-FOUND))
            (claim-id (var-get claim-nonce))
        )
        (asserts! (is-shipment-owner shipment-id) ERR-NOT-AUTHORIZED)
        (asserts! (get insured shipment) ERR-NOT-AUTHORIZED)
        (asserts! (is-eq (get status shipment) STATUS-VIOLATED) ERR-SHIPMENT-NOT-VIOLATED)
        (asserts! (<= amount (get insurance-amount shipment)) ERR-NOT-AUTHORIZED)
        
        (map-set insurance-claims claim-id {
            shipment-id: shipment-id,
            claimant: tx-sender,
            amount: amount,
            status: CLAIM-PENDING,
            filed-at: stacks-block-height,
            settled-at: none,
            evidence-hash: evidence-hash
        })
        
        (map-set shipments shipment-id 
            (merge shipment { status: STATUS-CLAIMED })
        )
        
        (var-set claim-nonce (+ claim-id u1))
        (ok claim-id)
    )
)

;; Approve insurance claim
(define-public (approve-claim (claim-id uint))
    (let
        (
            (claim (unwrap! (map-get? insurance-claims claim-id) ERR-CLAIM-NOT-FOUND))
        )
        (asserts! (is-contract-owner) ERR-NOT-AUTHORIZED)
        (asserts! (is-eq (get status claim) CLAIM-PENDING) ERR-ALREADY-SETTLED)
        
        (ok (map-set insurance-claims claim-id 
            (merge claim { 
                status: CLAIM-APPROVED,
                settled-at: (some stacks-block-height)
            })
        ))
    )
)

;; Reject insurance claim
(define-public (reject-claim (claim-id uint))
    (let
        (
            (claim (unwrap! (map-get? insurance-claims claim-id) ERR-CLAIM-NOT-FOUND))
        )
        (asserts! (is-contract-owner) ERR-NOT-AUTHORIZED)
        (asserts! (is-eq (get status claim) CLAIM-PENDING) ERR-ALREADY-SETTLED)
        
        (ok (map-set insurance-claims claim-id 
            (merge claim { 
                status: CLAIM-REJECTED,
                settled-at: (some stacks-block-height)
            })
        ))
    )
)

;; Read-only functions

(define-read-only (get-shipment (shipment-id uint))
    (ok (map-get? shipments shipment-id))
)

(define-read-only (get-temperature-reading (shipment-id uint) (reading-id uint))
    (ok (map-get? temperature-readings { shipment-id: shipment-id, reading-id: reading-id }))
)

(define-read-only (get-violation (shipment-id uint) (violation-id uint))
    (ok (map-get? violations { shipment-id: shipment-id, violation-id: violation-id }))
)

(define-read-only (get-claim (claim-id uint))
    (ok (map-get? insurance-claims claim-id))
)

(define-read-only (get-shipment-reading-count (shipment-id uint))
    (ok (get-reading-count shipment-id))
)

(define-read-only (get-shipment-violation-count (shipment-id uint))
    (ok (get-violation-count shipment-id))
)

(define-read-only (is-sensor-authorized (sensor principal))
    (ok (default-to false (map-get? authorized-sensors sensor)))
)

