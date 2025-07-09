;; Safety Equipment Contract
;; Ensures proper ladder and harness usage compliance

;; Constants
(define-constant CONTRACT_OWNER tx-sender)
(define-constant ERR_UNAUTHORIZED (err u200))
(define-constant ERR_ALREADY_EXISTS (err u201))
(define-constant ERR_NOT_FOUND (err u202))
(define-constant ERR_INVALID_INPUT (err u203))
(define-constant ERR_EXPIRED (err u204))
(define-constant ERR_NOT_CERTIFIED (err u205))

;; Data Variables
(define-data-var contract-active bool true)
(define-data-var certification-duration uint u52560) ;; ~1 year in blocks

;; Data Maps
(define-map equipment-registry
  { equipment-id: uint }
  {
    owner: principal,
    equipment-type: (string-ascii 20),
    certification-date: uint,
    expiry-date: uint,
    last-inspection: uint,
    status: (string-ascii 10)
  }
)

(define-map cleaner-certifications
  { cleaner: principal }
  {
    ladder-certified: bool,
    harness-certified: bool,
    certification-date: uint,
    expiry-date: uint,
    training-hours: uint
  }
)

(define-map equipment-usage
  { equipment-id: uint, job-id: uint }
  {
    cleaner: principal,
    start-time: uint,
    end-time: uint,
    safety-check-passed: bool
  }
)

(define-map safety-violations
  { violation-id: uint }
  {
    cleaner: principal,
    equipment-id: uint,
    violation-type: (string-ascii 50),
    severity: uint,
    reported-at: uint,
    resolved: bool
  }
)

;; Read-only functions
(define-read-only (get-equipment (equipment-id uint))
  (map-get? equipment-registry { equipment-id: equipment-id })
)

(define-read-only (get-cleaner-certification (cleaner principal))
  (map-get? cleaner-certifications { cleaner: cleaner })
)

(define-read-only (get-equipment-usage (equipment-id uint) (job-id uint))
  (map-get? equipment-usage { equipment-id: equipment-id, job-id: job-id })
)

(define-read-only (get-safety-violation (violation-id uint))
  (map-get? safety-violations { violation-id: violation-id })
)

(define-read-only (is-equipment-certified (equipment-id uint))
  (match (map-get? equipment-registry { equipment-id: equipment-id })
    equipment (and
      (is-eq (get status equipment) "active")
      (< block-height (get expiry-date equipment))
    )
    false
  )
)

(define-read-only (is-cleaner-certified (cleaner principal))
  (match (map-get? cleaner-certifications { cleaner: cleaner })
    cert (and
      (get ladder-certified cert)
      (get harness-certified cert)
      (< block-height (get expiry-date cert))
    )
    false
  )
)

(define-read-only (get-contract-info)
  {
    active: (var-get contract-active),
    owner: CONTRACT_OWNER,
    certification-duration: (var-get certification-duration)
  }
)

;; Public functions
(define-public (register-equipment (equipment-id uint) (equipment-type (string-ascii 20)))
  (let ((existing-equipment (map-get? equipment-registry { equipment-id: equipment-id })))
    (asserts! (var-get contract-active) ERR_UNAUTHORIZED)
    (asserts! (is-none existing-equipment) ERR_ALREADY_EXISTS)
    (asserts! (> (len equipment-type) u0) ERR_INVALID_INPUT)

    (map-set equipment-registry
      { equipment-id: equipment-id }
      {
        owner: tx-sender,
        equipment-type: equipment-type,
        certification-date: block-height,
        expiry-date: (+ block-height (var-get certification-duration)),
        last-inspection: block-height,
        status: "active"
      }
    )

    (ok equipment-id)
  )
)

(define-public (certify-cleaner (cleaner principal) (training-hours uint))
  (begin
    (asserts! (var-get contract-active) ERR_UNAUTHORIZED)
    (asserts! (is-eq tx-sender CONTRACT_OWNER) ERR_UNAUTHORIZED)
    (asserts! (>= training-hours u40) ERR_INVALID_INPUT)

    (map-set cleaner-certifications
      { cleaner: cleaner }
      {
        ladder-certified: true,
        harness-certified: true,
        certification-date: block-height,
        expiry-date: (+ block-height (var-get certification-duration)),
        training-hours: training-hours
      }
    )

    (ok true)
  )
)

(define-public (perform-safety-check (equipment-id uint) (job-id uint))
  (let ((equipment (unwrap! (map-get? equipment-registry { equipment-id: equipment-id }) ERR_NOT_FOUND)))
    (asserts! (var-get contract-active) ERR_UNAUTHORIZED)
    (asserts! (is-cleaner-certified tx-sender) ERR_NOT_CERTIFIED)
    (asserts! (is-equipment-certified equipment-id) ERR_EXPIRED)

    (map-set equipment-usage
      { equipment-id: equipment-id, job-id: job-id }
      {
        cleaner: tx-sender,
        start-time: block-height,
        end-time: u0,
        safety-check-passed: true
      }
    )

    (ok true)
  )
)

(define-public (complete-equipment-usage (equipment-id uint) (job-id uint))
  (let ((usage (unwrap! (map-get? equipment-usage { equipment-id: equipment-id, job-id: job-id }) ERR_NOT_FOUND)))
    (asserts! (var-get contract-active) ERR_UNAUTHORIZED)
    (asserts! (is-eq tx-sender (get cleaner usage)) ERR_UNAUTHORIZED)
    (asserts! (is-eq (get end-time usage) u0) ERR_INVALID_INPUT)

    (map-set equipment-usage
      { equipment-id: equipment-id, job-id: job-id }
      (merge usage { end-time: block-height })
    )

    (ok true)
  )
)

(define-public (report-safety-violation (violation-id uint) (cleaner principal) (equipment-id uint) (violation-type (string-ascii 50)) (severity uint))
  (let ((existing-violation (map-get? safety-violations { violation-id: violation-id })))
    (asserts! (var-get contract-active) ERR_UNAUTHORIZED)
    (asserts! (is-none existing-violation) ERR_ALREADY_EXISTS)
    (asserts! (> (len violation-type) u0) ERR_INVALID_INPUT)
    (asserts! (<= severity u5) ERR_INVALID_INPUT)

    (map-set safety-violations
      { violation-id: violation-id }
      {
        cleaner: cleaner,
        equipment-id: equipment-id,
        violation-type: violation-type,
        severity: severity,
        reported-at: block-height,
        resolved: false
      }
    )

    (ok violation-id)
  )
)

(define-public (resolve-safety-violation (violation-id uint))
  (let ((violation (unwrap! (map-get? safety-violations { violation-id: violation-id }) ERR_NOT_FOUND)))
    (asserts! (var-get contract-active) ERR_UNAUTHORIZED)
    (asserts! (is-eq tx-sender CONTRACT_OWNER) ERR_UNAUTHORIZED)

    (map-set safety-violations
      { violation-id: violation-id }
      (merge violation { resolved: true })
    )

    (ok true)
  )
)

(define-public (renew-equipment-certification (equipment-id uint))
  (let ((equipment (unwrap! (map-get? equipment-registry { equipment-id: equipment-id }) ERR_NOT_FOUND)))
    (asserts! (var-get contract-active) ERR_UNAUTHORIZED)
    (asserts! (is-eq tx-sender (get owner equipment)) ERR_UNAUTHORIZED)

    (map-set equipment-registry
      { equipment-id: equipment-id }
      (merge equipment {
        certification-date: block-height,
        expiry-date: (+ block-height (var-get certification-duration)),
        last-inspection: block-height
      })
    )

    (ok true)
  )
)

(define-public (renew-cleaner-certification (cleaner principal) (additional-training-hours uint))
  (let ((cert (unwrap! (map-get? cleaner-certifications { cleaner: cleaner }) ERR_NOT_FOUND)))
    (asserts! (var-get contract-active) ERR_UNAUTHORIZED)
    (asserts! (is-eq tx-sender CONTRACT_OWNER) ERR_UNAUTHORIZED)
    (asserts! (>= additional-training-hours u8) ERR_INVALID_INPUT)

    (map-set cleaner-certifications
      { cleaner: cleaner }
      (merge cert {
        certification-date: block-height,
        expiry-date: (+ block-height (var-get certification-duration)),
        training-hours: (+ (get training-hours cert) additional-training-hours)
      })
    )

    (ok true)
  )
)

;; Admin functions
(define-public (toggle-contract (active bool))
  (begin
    (asserts! (is-eq tx-sender CONTRACT_OWNER) ERR_UNAUTHORIZED)
    (var-set contract-active active)
    (ok active)
  )
)

(define-public (update-certification-duration (new-duration uint))
  (begin
    (asserts! (is-eq tx-sender CONTRACT_OWNER) ERR_UNAUTHORIZED)
    (asserts! (> new-duration u0) ERR_INVALID_INPUT)
    (var-set certification-duration new-duration)
    (ok new-duration)
  )
)
