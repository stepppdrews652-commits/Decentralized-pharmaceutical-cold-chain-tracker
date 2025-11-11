;; Decentralized Pharmaceutical Cold Chain Monitor
;; Records temperature data from IoT sensors, validates cold chain compliance,
;; triggers alerts for violations, and manages insurance claims for spoiled goods

;; Constants
(define-constant contract-owner tx-sender)
(define-constant err-owner-only (err u100))
(define-constant err-not-found (err u101))
(define-constant err-unauthorized (err u102))
(define-constant err-invalid-temperature (err u103))
(define-constant err-shipment-exists (err u104))
(define-constant err-shipment-not-active (err u105))
(define-constant err-claim-exists (err u106))
(define-constant err-invalid-status (err u107))

;; Temperature thresholds (in Celsius * 10 for precision)
(define-constant frozen-min-temp -800)  ;; -80C
(define-constant frozen-max-temp -600)  ;; -60C
(define-constant refrigerated-min-temp 20)  ;; 2C
(define-constant refrigerated-max-temp 80)  ;; 8C
(define-constant ambient-min-temp 150)  ;; 15C
(define-constant ambient-max-temp 250)  ;; 25C

;; Data Variables
(define-data-var shipment-counter uint u0)
(define-data-var reading-counter uint u0)
(define-data-var alert-counter uint u0)
(define-data-var claim-counter uint u0)

;; Data Maps

;; Shipment tracking
(define-map shipments
  { shipment-id: uint }
  {
    origin: (string-ascii 100),
    destination: (string-ascii 100),
    product-name: (string-ascii 100),
    temperature-zone: (string-ascii 20),
    owner: principal,
    carrier: principal,
    status: (string-ascii 20),
    created-at: uint,
    completed-at: (optional uint),
    is-compliant: bool
  }
)

;; Temperature readings
(define-map temperature-readings
  { reading-id: uint }
  {
    shipment-id: uint,
    temperature: int,
    sensor-id: (string-ascii 50),
    timestamp: uint,
    location: (string-ascii 100),
    recorded-by: principal
  }
)

;; Violation alerts
(define-map violation-alerts
  { alert-id: uint }
  {
    shipment-id: uint,
    reading-id: uint,
    violation-type: (string-ascii 50),
    severity: (string-ascii 20),
    timestamp: uint,
    resolved: bool,
    resolution-notes: (optional (string-ascii 200))
  }
)

;; Insurance claims
(define-map insurance-claims
  { claim-id: uint }
  {
    shipment-id: uint,
    claimant: principal,
    claim-amount: uint,
    status: (string-ascii 20),
    filed-at: uint,
    resolved-at: (optional uint),
    evidence-hash: (string-ascii 64)
  }
)

;; Authorized sensors
(define-map authorized-sensors
  { sensor-id: (string-ascii 50) }
  { is-authorized: bool, registered-by: principal }
)

;; Public Functions

;; Register a new shipment
(define-public (register-shipment 
    (origin (string-ascii 100))
    (destination (string-ascii 100))
    (product-name (string-ascii 100))
    (temperature-zone (string-ascii 20))
    (carrier principal))
  (let
    (
      (new-shipment-id (+ (var-get shipment-counter) u1))
    )
    (asserts! (is-eq tx-sender contract-owner) err-owner-only)
    (map-set shipments
      { shipment-id: new-shipment-id }
      {
        origin: origin,
        destination: destination,
        product-name: product-name,
        temperature-zone: temperature-zone,
        owner: tx-sender,
        carrier: carrier,
        status: "active",
        created-at: stacks-block-height,
        completed-at: none,
        is-compliant: true
      }
    )
    (var-set shipment-counter new-shipment-id)
    (ok new-shipment-id)
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
      (new-reading-id (+ (var-get reading-counter) u1))
      (shipment (unwrap! (map-get? shipments { shipment-id: shipment-id }) err-not-found))
      (sensor (unwrap! (map-get? authorized-sensors { sensor-id: sensor-id }) err-unauthorized))
    )
    (asserts! (is-eq (get status shipment) "active") err-shipment-not-active)
    (asserts! (get is-authorized sensor) err-unauthorized)
    
    ;; Store temperature reading
    (map-set temperature-readings
      { reading-id: new-reading-id }
      {
        shipment-id: shipment-id,
        temperature: temperature,
        sensor-id: sensor-id,
        timestamp: stacks-block-height,
        location: location,
        recorded-by: tx-sender
      }
    )
    (var-set reading-counter new-reading-id)
    
    ;; Check for violations
    (unwrap-panic (check-temperature-compliance shipment-id new-reading-id temperature (get temperature-zone shipment)))
    
    (ok new-reading-id)
  )
)

;; Check temperature compliance and create alert if needed
(define-private (check-temperature-compliance
    (shipment-id uint)
    (reading-id uint)
    (temperature int)
    (zone (string-ascii 20)))
  (let
    (
      (is-violation (check-violation temperature zone))
      (new-alert-id (+ (var-get alert-counter) u1))
    )
    (if is-violation
      (begin
        (map-set violation-alerts
          { alert-id: new-alert-id }
          {
            shipment-id: shipment-id,
            reading-id: reading-id,
            violation-type: "temperature-excursion",
            severity: (get-violation-severity temperature zone),
            timestamp: stacks-block-height,
            resolved: false,
            resolution-notes: none
          }
        )
        (var-set alert-counter new-alert-id)
        ;; Mark shipment as non-compliant
        (map-set shipments
          { shipment-id: shipment-id }
          (merge (unwrap-panic (map-get? shipments { shipment-id: shipment-id }))
                 { is-compliant: false })
        )
        (ok true)
      )
      (ok false)
    )
  )
)

;; File insurance claim
(define-public (file-insurance-claim
    (shipment-id uint)
    (claim-amount uint)
    (evidence-hash (string-ascii 64)))
  (let
    (
      (new-claim-id (+ (var-get claim-counter) u1))
      (shipment (unwrap! (map-get? shipments { shipment-id: shipment-id }) err-not-found))
    )
    (asserts! (or (is-eq tx-sender (get owner shipment)) 
                  (is-eq tx-sender (get carrier shipment))) 
              err-unauthorized)
    (asserts! (not (get is-compliant shipment)) err-invalid-status)
    
    (map-set insurance-claims
      { claim-id: new-claim-id }
      {
        shipment-id: shipment-id,
        claimant: tx-sender,
        claim-amount: claim-amount,
        status: "pending",
        filed-at: stacks-block-height,
        resolved-at: none,
        evidence-hash: evidence-hash
      }
    )
    (var-set claim-counter new-claim-id)
    (ok new-claim-id)
  )
)

;; Complete shipment
(define-public (complete-shipment (shipment-id uint))
  (let
    (
      (shipment (unwrap! (map-get? shipments { shipment-id: shipment-id }) err-not-found))
    )
    (asserts! (or (is-eq tx-sender (get owner shipment))
                  (is-eq tx-sender (get carrier shipment)))
              err-unauthorized)
    (asserts! (is-eq (get status shipment) "active") err-shipment-not-active)
    
    (map-set shipments
      { shipment-id: shipment-id }
      (merge shipment
        {
          status: "completed",
          completed-at: (some stacks-block-height)
        }
      )
    )
    (ok true)
  )
)

;; Authorize sensor
(define-public (authorize-sensor (sensor-id (string-ascii 50)))
  (begin
    (asserts! (is-eq tx-sender contract-owner) err-owner-only)
    (map-set authorized-sensors
      { sensor-id: sensor-id }
      { is-authorized: true, registered-by: tx-sender }
    )
    (ok true)
  )
)

;; Resolve alert
(define-public (resolve-alert (alert-id uint) (resolution-notes (string-ascii 200)))
  (let
    (
      (alert (unwrap! (map-get? violation-alerts { alert-id: alert-id }) err-not-found))
    )
    (asserts! (is-eq tx-sender contract-owner) err-owner-only)
    (map-set violation-alerts
      { alert-id: alert-id }
      (merge alert
        {
          resolved: true,
          resolution-notes: (some resolution-notes)
        }
      )
    )
    (ok true)
  )
)

;; Process insurance claim
(define-public (process-claim (claim-id uint) (new-status (string-ascii 20)))
  (let
    (
      (claim (unwrap! (map-get? insurance-claims { claim-id: claim-id }) err-not-found))
    )
    (asserts! (is-eq tx-sender contract-owner) err-owner-only)
    (map-set insurance-claims
      { claim-id: claim-id }
      (merge claim
        {
          status: new-status,
          resolved-at: (some stacks-block-height)
        }
      )
    )
    (ok true)
  )
)

;; Read-only Functions

;; Get shipment details
(define-read-only (get-shipment (shipment-id uint))
  (map-get? shipments { shipment-id: shipment-id })
)

;; Get temperature reading
(define-read-only (get-reading (reading-id uint))
  (map-get? temperature-readings { reading-id: reading-id })
)

;; Get alert details
(define-read-only (get-alert (alert-id uint))
  (map-get? violation-alerts { alert-id: alert-id })
)

;; Get claim details
(define-read-only (get-claim (claim-id uint))
  (map-get? insurance-claims { claim-id: claim-id })
)

;; Get shipment compliance status
(define-read-only (is-shipment-compliant (shipment-id uint))
  (match (map-get? shipments { shipment-id: shipment-id })
    shipment (ok (get is-compliant shipment))
    err-not-found
  )
)

;; Get counters
(define-read-only (get-shipment-count)
  (ok (var-get shipment-counter))
)

(define-read-only (get-reading-count)
  (ok (var-get reading-counter))
)

(define-read-only (get-alert-count)
  (ok (var-get alert-counter))
)

(define-read-only (get-claim-count)
  (ok (var-get claim-counter))
)

;; Private Helper Functions

;; Check if temperature is a violation
(define-private (check-violation (temperature int) (zone (string-ascii 20)))
  (if (is-eq zone "frozen")
    (or (< temperature frozen-min-temp) (> temperature frozen-max-temp))
    (if (is-eq zone "refrigerated")
      (or (< temperature refrigerated-min-temp) (> temperature refrigerated-max-temp))
      (if (is-eq zone "ambient")
        (or (< temperature ambient-min-temp) (> temperature ambient-max-temp))
        false
      )
    )
  )
)

;; Determine violation severity
(define-private (get-violation-severity (temperature int) (zone (string-ascii 20)))
  (let
    (
      (deviation (if (is-eq zone "frozen")
                    (if (< temperature frozen-min-temp)
                      (- frozen-min-temp temperature)
                      (- temperature frozen-max-temp))
                    (if (is-eq zone "refrigerated")
                      (if (< temperature refrigerated-min-temp)
                        (- refrigerated-min-temp temperature)
                        (- temperature refrigerated-max-temp))
                      (if (< temperature ambient-min-temp)
                        (- ambient-min-temp temperature)
                        (- temperature ambient-max-temp)))))
    )
    (if (> deviation 50)
      "critical"
      (if (> deviation 20)
        "high"
        "medium"
      )
    )
  )
)

;; title: cold-chain-monitor
;; version:
;; summary:
;; description:

;; traits
;;

;; token definitions
;;

;; constants
;;

;; data vars
;;

;; data maps
;;

;; public functions
;;

;; read only functions
;;

;; private functions
;;

