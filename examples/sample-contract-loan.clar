
(use-trait cb-trait 'ST1PQHQKV0RJXZFY1DGX8MNSNYVE3VGZJSRTPGZGM.dlc-link-callback-trait-v2.dlc-link-callback-trait)
(impl-trait 'ST1PQHQKV0RJXZFY1DGX8MNSNYVE3VGZJSRTPGZGM.dlc-link-callback-trait-v2.dlc-link-callback-trait)

;; Error constants
(define-constant err-cant-unwrap (err u1000))
(define-constant err-contract-call-failed (err u1001))
(define-constant err-cant-get-loan-id-by-uuid (err u1002))
(define-constant err-cant-unwrap-check-liquidation (err u1003))
(define-constant err-cant-unwrap-liquidate-loan (err u1004))
(define-constant err-unauthorised (err u1005))
(define-constant err-unknown-loan-contract (err u1006))
(define-constant err-doesnt-need-liquidation (err u1007))
(define-constant err-dlc-already-funded (err u1008))
(define-constant err-dlc-not-funded (err u1009))
(define-constant err-stablecoin-issue-failed (err u1010))
(define-constant err-stablecoin-repay-failed (err u1011))
(define-constant err-balance-negative (err u1012))
(define-constant err-not-repaid (err u1013))

;; Status Enum
(define-constant status-not-ready "not-ready")
(define-constant status-ready "ready")
(define-constant status-funded "funded")
(define-constant status-pre-repaid "pre-repaid")
(define-constant status-repaid "repaid")
(define-constant status-pre-liquidated "pre-liquidated")
(define-constant status-liquidated "liquidated")

(define-constant ten-to-power-2 u100)
(define-constant ten-to-power-6 u1000000)
(define-constant ten-to-power-8 u100000000)
(define-constant ten-to-power-12 u1000000000000)
(define-constant ten-to-power-16 u10000000000000000)

;; Contract owner
(define-constant contract-owner tx-sender)

;; Contract name bindings
(define-constant sample-protocol-contract .sample-contract-loan-v0-1)

;; @desc A map to store "loans": information about a DLC
(define-map loans
  uint ;; The loan-id
  {
    dlc_uuid: (optional (buff 32)),
    ;; Other data about the loan and their specific contract
    status: (string-ascii 14),
    vault-loan: uint, ;; the borrowed amount
    vault-collateral: uint, ;; btc deposit in sats
    liquidation-ratio: uint, ;; the collateral/loan ratio below which liquidation can happen, with two decimals precision (140% = u14000)
    liquidation-fee: uint,  ;; additional fee taken during liquidation, two decimals precision (10% = u1000)
    owner: principal ;; the stacks account owning this loan
  }
)

;; @desc A map to store loans belonging to a principal
(define-map creator-loan-ids principal (list 50 uint))

;; @desc A map to link uuids and loan-ids
;; used to reverse-lookup loan-ids when the dlc-manager contract gives us a UUID
(define-map uuid-loan-id
  (buff 32)
  uint
)

(define-read-only (get-loan (loan-id uint))
  (map-get? loans loan-id)
)

(define-read-only (get-loan-id-by-uuid (uuid (buff 32)))
  (map-get? uuid-loan-id uuid)
)

;; @desc get all loan IDs for given creator
(define-read-only (get-creator-loan-ids (creator principal))
  (default-to
    (list)
    (map-get? creator-loan-ids creator)
  )
)

;; @desc get all loans info for given creator
(define-read-only (get-creator-loans (creator principal))
  (let (
    (loan-ids (get-creator-loan-ids creator))
  )
    (map get-loan loan-ids)
  )
)

;; An auto-incrementing loan-id will be used to know which incoming uuid is connected to which loan
(define-data-var last-loan-id uint u0)

(define-read-only (get-last-loan-id)
  (ok (var-get last-loan-id))
)

(define-read-only (get-loan-by-uuid (uuid (buff 32)))
  (let (
    (loan-id (unwrap! (get-loan-id-by-uuid uuid ) err-cant-get-loan-id-by-uuid ))
    (loan (unwrap! (get-loan loan-id) err-unknown-loan-contract))
    )
    (ok loan)
  )
)

(define-private (shift-value (value uint) (shift uint))
  (* value shift)
)

(define-private (unshift-value (value uint) (shift uint))
  (/ value shift)
)

(define-private (set-status (loan-id uint) (new-status (string-ascii 14)))
  (let (
    (loan (unwrap! (get-loan loan-id) err-unknown-loan-contract))
    )
    (begin
      (print { loan-id: loan-id, uuid: (get dlc_uuid loan), status: new-status })
      (map-set loans loan-id (merge loan { status: new-status }))
    )
    (ok true)
  )
)

;; ---------------------------------------------------------
;; Main Functions
;; ---------------------------------------------------------

;; @desc An example function to initiate the creation of a DLC loan.
;; - Increments the loan-id
;; - Calls the dlc-manager-contract's create-dlc function to initiate the creation
;; The DLC Contract will call back into the provided 'target' contract with the resulting UUID (and the provided loan-id).
;; See scripts/setup-loan.ts for an example of calling it.
(define-public (setup-loan (btc-deposit uint) (liquidation-ratio uint) (liquidation-fee uint) (emergency-refund-time uint))
    (let
      (
        (loan-id (+ (var-get last-loan-id) u1))
        (target sample-protocol-contract)
        (current-loan-ids (get-creator-loan-ids tx-sender))
      )
      (var-set last-loan-id loan-id)
      (begin
          (map-set loans loan-id {
            dlc_uuid: none,
            status: status-not-ready,
            vault-loan: u0,
            vault-collateral: btc-deposit,
            liquidation-ratio: liquidation-ratio,
            liquidation-fee: liquidation-fee,
            owner: tx-sender
          })
          (try! (set-status loan-id status-not-ready))
          (map-set creator-loan-ids tx-sender (unwrap-panic (as-max-len? (append current-loan-ids loan-id) u50)))
          (unwrap! (ok (contract-call? 'ST1PQHQKV0RJXZFY1DGX8MNSNYVE3VGZJSRTPGZGM.dlc-manager-priced-v0-1 create-dlc emergency-refund-time target loan-id)) err-contract-call-failed)
      )
    )
)

;; @desc Callback function after succesful DLC creation
;; Implemented from the trait, this is what is used to pass back the uuid created by the DLC system
;; called by the dlc-manager contract
(define-public (post-create-dlc-handler (loan-id uint) (uuid (buff 32)))
    (begin
      ;; If creation was successful, we save the results in the local maps
        (map-set loans loan-id (
            merge (unwrap! (map-get? loans loan-id) err-unknown-loan-contract ) {
            dlc_uuid: (some uuid)
        }))
        (try! (set-status loan-id status-ready))
        (map-set uuid-loan-id uuid loan-id)
        (ok true)
    )
)

;; @desc Externally set a given DLCs status to funded.
;; Called by the dlc-manager contract after the necessary BTC events have happened.
(define-public (set-status-funded (uuid (buff 32)))
  (let (
    (loan-id (unwrap! (get-loan-id-by-uuid uuid ) err-cant-get-loan-id-by-uuid ))
    (loan (unwrap! (get-loan loan-id) err-unknown-loan-contract))
    )
    (asserts! (not (is-eq (get status loan) status-funded)) err-dlc-already-funded)
    (begin
      (try! (set-status loan-id status-funded))
      (map-set loans loan-id (merge loan { status: status-funded }))
    )
    (ok true)
  )
)

;; amount has 6 decimals e.g. $100 = u100000000
(define-public (borrow (loan-id uint) (amount uint))
  (let (
    (loan (unwrap! (get-loan loan-id) err-unknown-loan-contract))
    (vault-loan-amount (get vault-loan loan))
    )
    (asserts! (is-eq (get owner loan) tx-sender) err-unauthorised)
    (asserts! (is-eq (get status loan) status-funded) err-dlc-not-funded)
    (map-set loans loan-id (merge loan { vault-loan: (+ vault-loan-amount amount) }))
    (unwrap! (ok (contract-call? 'ST1PQHQKV0RJXZFY1DGX8MNSNYVE3VGZJSRTPGZGM.dlc-stablecoin transfer amount sample-protocol-contract (get owner loan) none)) err-stablecoin-issue-failed)
  )
)

(define-public (repay (loan-id uint) (amount uint))
  (let (
    (loan (unwrap! (get-loan loan-id) err-unknown-loan-contract))
    (vault-loan-amount (get vault-loan loan))
    (new-balance (- vault-loan-amount amount))
    )
    (asserts! (is-eq (get owner loan) tx-sender) err-unauthorised)
    (asserts! (is-eq (get status loan) status-funded) err-dlc-not-funded)
    (asserts! (>= new-balance u0) err-balance-negative)
    (map-set loans loan-id (merge loan { vault-loan: new-balance }))
    (unwrap! (ok (contract-call? 'ST1PQHQKV0RJXZFY1DGX8MNSNYVE3VGZJSRTPGZGM.dlc-stablecoin transfer amount (get owner loan) sample-protocol-contract none)) err-stablecoin-repay-failed)
  )
)

;; @desc An example function for closing the loan and initiating the closing of a DLC.
(define-public (close-loan (loan-id uint))
  (let (
    (loan (unwrap! (get-loan loan-id) err-unknown-loan-contract))
    (uuid (unwrap! (get dlc_uuid loan) err-cant-unwrap))
    )
    (begin
      (asserts! (is-eq (get vault-loan loan) u0) err-not-repaid)
      (try! (set-status loan-id status-pre-repaid))
      (unwrap! (ok (as-contract (contract-call? 'ST1PQHQKV0RJXZFY1DGX8MNSNYVE3VGZJSRTPGZGM.dlc-manager-priced-v0-1 close-dlc uuid u0))) err-contract-call-failed)
    )
  )
)

;; @desc Callback function: called after sucessful DLC closing
;; Implemented from the trait
;; When this function is called by the dlc-manager contract, we know the closing was successful, so we can finalise changes in this contract.
(define-public (post-close-dlc-handler (uuid (buff 32)))
  (let (
    (loan-id (unwrap! (get-loan-id-by-uuid uuid ) err-cant-get-loan-id-by-uuid ))
    (loan (unwrap! (get-loan loan-id) err-unknown-loan-contract))
    (currstatus (get status loan) )
    (newstatus  (unwrap! (if (is-eq currstatus status-pre-repaid)
                    (ok status-repaid)
                    (ok status-liquidated)
            ) err-cant-unwrap)
    ))
    (begin
      (try! (set-status loan-id newstatus))
    )
    (ok true)
  )
)

;; @desc Closing flow with price data.
(define-public (attempt-liquidate (loan-id uint))
  (let (
    (loan (unwrap! (get-loan loan-id) err-unknown-loan-contract))
    (uuid (unwrap! (get dlc_uuid loan) err-cant-unwrap))
    )
    (unwrap! (ok (as-contract (contract-call? 'ST1PQHQKV0RJXZFY1DGX8MNSNYVE3VGZJSRTPGZGM.dlc-manager-priced-v0-1 get-btc-price uuid))) err-contract-call-failed)
  )
)

;; @desc Called by the dlc-manager contract with the validated BTC price.
;; Liquidates loan if necessary at given level
(define-public (get-btc-price-callback (btc-price uint) (uuid (buff 32)))
  (let (
    (loan-id (unwrap! (get-loan-id-by-uuid uuid) err-cant-get-loan-id-by-uuid ))
    (loan (unwrap! (get-loan loan-id) err-unknown-loan-contract))
    )
    (asserts! (unwrap! (check-liquidation loan-id btc-price) err-cant-unwrap-check-liquidation) err-doesnt-need-liquidation)
    (ok (unwrap! (liquidate-loan loan-id btc-price) err-cant-unwrap-liquidate-loan))
  )
)

;; @desc Helper function to calculate if a loan is underwater at a given BTC price
(define-read-only (check-liquidation (loan-id uint) (btc-price uint))
  (let (
    (loan (unwrap! (get-loan loan-id) err-unknown-loan-contract))
    (collateral-value (get-collateral-value (get vault-collateral loan) btc-price))
    (strike-price (/ (* (get vault-loan loan) (get liquidation-ratio loan)) u100000000))
    )
    (ok (<= collateral-value strike-price))
  )
)

;; @desc Calculating loan collateral value for a given btc-price * (10**8), with pennies precision.
;; Since the deposit is in Sats, after multiplication we first shift by 2, then ushift by 16 to get pennies precision ($12345.67 = u1234567)
(define-private (get-collateral-value (btc-deposit uint) (btc-price uint))
  (unshift-value (shift-value (* btc-deposit btc-price) ten-to-power-2) ten-to-power-16)
)

;; @desc An example function to initiate the liquidation of a DLC loan contract.
;; If liquidation is required, this function will initiate a simple close-dlc flow with the calculated payout-ratio
(define-private (liquidate-loan (loan-id uint) (btc-price uint))
  (let (
    (loan (unwrap! (get-loan loan-id) err-unknown-loan-contract))
    (uuid (unwrap! (get dlc_uuid loan) err-cant-unwrap))
    (payout-ratio (unwrap! (get-payout-ratio loan-id btc-price) err-cant-unwrap))
    )
    (begin
      (try! (set-status loan-id status-pre-liquidated))
      (unwrap! (ok (contract-call? 'ST1PQHQKV0RJXZFY1DGX8MNSNYVE3VGZJSRTPGZGM.dlc-manager-priced-v0-1 close-dlc uuid payout-ratio)) err-contract-call-failed)
    )
  )
)

;; @desc Returns the resulting payout-ratio at the given btc-price (shifted by 10**8).
;; This value is sent to the Oracle system for signing a point on the linear payout curve.
;; using uints, this means return values between 0-100000000 (0.00-100.00 with room for extra precision in the future)
;; 0.00 means the borrower gets back its deposit, 100.00 means the entire collateral gets taken by the protocol.
(define-read-only (get-payout-ratio (loan-id uint) (btc-price uint))
  (let (
    (loan (unwrap! (get-loan loan-id) err-unknown-loan-contract))
    (collateral-value (get-collateral-value (get vault-collateral loan) btc-price))
    ;; the ratio the protocol has to sell to liquidators:
    (sell-to-liquidators-ratio (/ (shift-value (get vault-loan loan) ten-to-power-12) collateral-value))
    ;; the additional liquidation-fee percentage is calculated into the result. Since it is shifted by 10000, we divide:
    (payout-ratio-precise (+ sell-to-liquidators-ratio (* (/ sell-to-liquidators-ratio u10000) (get liquidation-fee loan))))
    ;; The final payout-ratio is a truncated version:
    (payout-ratio (unshift-value payout-ratio-precise ten-to-power-8))
    )
    ;; We cap result to be between the desired bounds
    (begin
      (if (unwrap! (check-liquidation loan-id btc-price) err-cant-unwrap)
          (if (>= payout-ratio (shift-value u1 ten-to-power-8))
            (ok (shift-value u1 ten-to-power-8))
            (ok payout-ratio))
        (ok u0)
      )
    )
  )
)
