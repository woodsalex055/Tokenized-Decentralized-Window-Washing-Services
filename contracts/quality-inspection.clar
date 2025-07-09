;; Quality Inspection Contract
;; Verifies window cleaning completion standards

;; Constants
(define-constant CONTRACT_OWNER tx-sender)
(define-constant ERR_UNAUTHORIZED (err u300))
(define-constant ERR_ALREADY_EXISTS (err u301))
(define-constant ERR_NOT_FOUND (err u302))
(define-constant ERR_INVALID_INPUT (err u303))
(define-constant ERR_ALREADY_INSPECTED (err u304))
(define-constant ERR_INSPECTION_PENDING (err u305))

;; Data Variables
(define-data-var contract-active bool true)
(define-data-var min-quality-score uint u7)
(define-data-var inspection-window uint u144) ;; ~24 hours in blocks

;; Data Maps
(define-map quality-inspectors
  { inspector: principal }
  {
    certified: bool,
    certification-date: uint,
    inspections-completed: uint,
    average-rating: uint
  }
)

(define-map cleaning-jobs
  { job-id: uint }
  {
    building-id: uint,
    cleaner: principal,
    completion-time: uint,
    inspection-required: bool,
    inspection-completed: bool,
    quality-score: uint,
    inspector: (optional principal)
  }
)

(define-map quality-inspections
  { job-id: uint }
  {
    inspector: principal,
    inspection-date: uint,
    overall-score: uint,
    cleanliness-score: uint,
    streak-score: uint,
    technique-score: uint,
    notes: (string-ascii 200),
    passed: bool
  }
)

(define-map quality-standards
  { standard-id: uint }
  {
    name: (string-ascii 50),
    description: (string-ascii 200),
    min-score: uint,
    weight: uint,
    active: bool
  }
)

;; Read-only functions
(define-read-only (get-quality-inspector (inspector principal))
  (map-get? quality-inspectors { inspector: inspector })
)

(define-read-only (get-cleaning-job (job-id uint))
  (map-get? cleaning-jobs { job-id: job-id })
)

(define-read-only (get-quality-inspection (job-id uint))
  (map-get? quality-inspections { job-id: job-id })
)

(define-read-only (get-quality-standard (standard-id uint))
  (map-get? quality-standards { standard-id: standard-id })
)

(define-read-only (is-inspector-certified (inspector principal))
  (match (map-get? quality-inspectors { inspector: inspector })
    inspector-data (get certified inspector-data)
    false
  )
)

(define-read-only (is-job-inspection-due (job-id uint))
  (match (map-get? cleaning-jobs { job-id: job-id })
    job (and
      (get inspection-required job)
      (not (get inspection-completed job))
      (< (+ (get completion-time job) (var-get inspection-window)) block-height)
    )
    false
  )
)

(define-read-only (calculate-quality-score (cleanliness uint) (streak uint) (technique uint))
  (let ((total-score (+ (+ (* cleanliness u4) (* streak u3)) (* technique u3))))
    (/ total-score u10)
  )
)

(define-read-only (get-contract-info)
  {
    active: (var-get contract-active),
    owner: CONTRACT_OWNER,
    min-quality-score: (var-get min-quality-score),
    inspection-window: (var-get inspection-window)
  }
)

;; Public functions
(define-public (register-inspector (inspector principal))
  (let ((existing-inspector (map-get? quality-inspectors { inspector: inspector })))
    (asserts! (var-get contract-active) ERR_UNAUTHORIZED)
    (asserts! (is-eq tx-sender CONTRACT_OWNER) ERR_UNAUTHORIZED)
    (asserts! (is-none existing-inspector) ERR_ALREADY_EXISTS)

    (map-set quality-inspectors
      { inspector: inspector }
      {
        certified: true,
        certification-date: block-height,
        inspections-completed: u0,
        average-rating: u0
      }
    )

    (ok true)
  )
)

(define-public (register-cleaning-job (job-id uint) (building-id uint) (cleaner principal) (requires-inspection bool))
  (let ((existing-job (map-get? cleaning-jobs { job-id: job-id })))
    (asserts! (var-get contract-active) ERR_UNAUTHORIZED)
    (asserts! (is-none existing-job) ERR_ALREADY_EXISTS)

    (map-set cleaning-jobs
      { job-id: job-id }
      {
        building-id: building-id,
        cleaner: cleaner,
        completion-time: block-height,
        inspection-required: requires-inspection,
        inspection-completed: false,
        quality-score: u0,
        inspector: none
      }
    )

    (ok job-id)
  )
)

(define-public (conduct-quality-inspection (job-id uint) (cleanliness-score uint) (streak-score uint) (technique-score uint) (notes (string-ascii 200)))
  (let ((job (unwrap! (map-get? cleaning-jobs { job-id: job-id }) ERR_NOT_FOUND)))
    (asserts! (var-get contract-active) ERR_UNAUTHORIZED)
    (asserts! (is-inspector-certified tx-sender) ERR_UNAUTHORIZED)
    (asserts! (get inspection-required job) ERR_INVALID_INPUT)
    (asserts! (not (get inspection-completed job)) ERR_ALREADY_INSPECTED)
    (asserts! (<= cleanliness-score u10) ERR_INVALID_INPUT)
    (asserts! (<= streak-score u10) ERR_INVALID_INPUT)
    (asserts! (<= technique-score u10) ERR_INVALID_INPUT)

    (let ((overall-score (calculate-quality-score cleanliness-score streak-score technique-score))
          (inspection-passed (>= overall-score (var-get min-quality-score))))

      (map-set quality-inspections
        { job-id: job-id }
        {
          inspector: tx-sender,
          inspection-date: block-height,
          overall-score: overall-score,
          cleanliness-score: cleanliness-score,
          streak-score: streak-score,
          technique-score: technique-score,
          notes: notes,
          passed: inspection-passed
        }
      )

      (map-set cleaning-jobs
        { job-id: job-id }
        (merge job {
          inspection-completed: true,
          quality-score: overall-score,
          inspector: (some tx-sender)
        })
      )

      ;; Update inspector stats
      (let ((inspector-data (unwrap! (map-get? quality-inspectors { inspector: tx-sender }) ERR_NOT_FOUND))
            (new-inspection-count (+ (get inspections-completed inspector-data) u1))
            (current-avg (get average-rating inspector-data))
            (new-avg (if (is-eq current-avg u0)
                        overall-score
                        (/ (+ (* current-avg (get inspections-completed inspector-data)) overall-score) new-inspection-count))))

        (map-set quality-inspectors
          { inspector: tx-sender }
          (merge inspector-data {
            inspections-completed: new-inspection-count,
            average-rating: new-avg
          })
        )
      )

      (ok inspection-passed)
    )
  )
)

(define-public (create-quality-standard (standard-id uint) (name (string-ascii 50)) (description (string-ascii 200)) (min-score uint) (weight uint))
  (let ((existing-standard (map-get? quality-standards { standard-id: standard-id })))
    (asserts! (var-get contract-active) ERR_UNAUTHORIZED)
    (asserts! (is-eq tx-sender CONTRACT_OWNER) ERR_UNAUTHORIZED)
    (asserts! (is-none existing-standard) ERR_ALREADY_EXISTS)
    (asserts! (> (len name) u0) ERR_INVALID_INPUT)
    (asserts! (<= min-score u10) ERR_INVALID_INPUT)
    (asserts! (> weight u0) ERR_INVALID_INPUT)

    (map-set quality-standards
      { standard-id: standard-id }
      {
        name: name,
        description: description,
        min-score: min-score,
        weight: weight,
        active: true
      }
    )

    (ok standard-id)
  )
)

(define-public (update-quality-standard (standard-id uint) (min-score uint) (weight uint) (active bool))
  (let ((standard (unwrap! (map-get? quality-standards { standard-id: standard-id }) ERR_NOT_FOUND)))
    (asserts! (var-get contract-active) ERR_UNAUTHORIZED)
    (asserts! (is-eq tx-sender CONTRACT_OWNER) ERR_UNAUTHORIZED)
    (asserts! (<= min-score u10) ERR_INVALID_INPUT)
    (asserts! (> weight u0) ERR_INVALID_INPUT)

    (map-set quality-standards
      { standard-id: standard-id }
      (merge standard {
        min-score: min-score,
        weight: weight,
        active: active
      })
    )

    (ok true)
  )
)

(define-public (revoke-inspector-certification (inspector principal))
  (let ((inspector-data (unwrap! (map-get? quality-inspectors { inspector: inspector }) ERR_NOT_FOUND)))
    (asserts! (var-get contract-active) ERR_UNAUTHORIZED)
    (asserts! (is-eq tx-sender CONTRACT_OWNER) ERR_UNAUTHORIZED)

    (map-set quality-inspectors
      { inspector: inspector }
      (merge inspector-data { certified: false })
    )

    (ok true)
  )
)

(define-public (request-reinspection (job-id uint))
  (let ((job (unwrap! (map-get? cleaning-jobs { job-id: job-id }) ERR_NOT_FOUND)))
    (asserts! (var-get contract-active) ERR_UNAUTHORIZED)
    (asserts! (is-eq tx-sender (get cleaner job)) ERR_UNAUTHORIZED)
    (asserts! (get inspection-completed job) ERR_INSPECTION_PENDING)
    (asserts! (< (get quality-score job) (var-get min-quality-score)) ERR_INVALID_INPUT)

    (map-set cleaning-jobs
      { job-id: job-id }
      (merge job {
        inspection-completed: false,
        quality-score: u0,
        inspector: none
      })
    )

    (map-delete quality-inspections { job-id: job-id })

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

(define-public (update-min-quality-score (new-score uint))
  (begin
    (asserts! (is-eq tx-sender CONTRACT_OWNER) ERR_UNAUTHORIZED)
    (asserts! (<= new-score u10) ERR_INVALID_INPUT)
    (var-set min-quality-score new-score)
    (ok new-score)
  )
)

(define-public (update-inspection-window (new-window uint))
  (begin
    (asserts! (is-eq tx-sender CONTRACT_OWNER) ERR_UNAUTHORIZED)
    (asserts! (> new-window u0) ERR_INVALID_INPUT)
    (var-set inspection-window new-window)
    (ok new-window)
  )
)
