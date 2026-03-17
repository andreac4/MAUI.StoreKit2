//
//  StoreKit2Framework.swift
//  StoreKit2Framework
//
//  Created by Andrea Caoli on 17/03/2026.
//

import Foundation
import StoreKit

@available(iOS 15.0, *)
@objc public protocol PaymentManagerDelegate: AnyObject {
    @objc optional func paymentManagerDidFinishPurchase(_ productId: String, transaction: PaymentTransaction)
    @objc optional func paymentManagerDidFailPurchase(_ productId: String, error: String)
    @objc optional func paymentManagerDidUpdateProducts(_ products: [PaymentProduct])
    @objc optional func paymentManagerDidRestorePurchases(_ transactions: [PaymentTransaction])
}

@available(iOS 15.0, *)
@objc public class PaymentProduct: NSObject {
    @objc public let productId: String
    @objc public let displayName: String
    @objc public let productDescription: String
    @objc public let price: NSDecimalNumber
    @objc public let displayPrice: String
    @objc public let productType: String

    public init(product: Product) {
        self.productId = product.id
        self.displayName = product.displayName
        self.productDescription = product.description
        self.price = NSDecimalNumber(decimal: product.price)
        self.displayPrice = product.displayPrice

        switch product.type {
        case .consumable:
            self.productType = "consumable"
        case .nonConsumable:
            self.productType = "nonConsumable"
        case .autoRenewable:
            self.productType = "autoRenewable"
        case .nonRenewable:
            self.productType = "nonRenewable"
        default:
            self.productType = "unknown"
        }

        super.init()
    }
}

@available(iOS 15.0, *)
@objc public class PaymentTransaction: NSObject {
    @objc public let transactionId: String
    @objc public let originalTransactionId: String
    @objc public let productId: String
    @objc public let purchaseDate: Date
    @objc public let originalPurchaseDate: Date
    @objc public let expirationDate: Date?
    @objc public let isUpgraded: Bool
    @objc public let revocationDate: Date?
    @objc public let revocationReason: String?
    @objc public let isIntroOffer: Bool
    @objc public let ownershipType: String

    public init(transaction: Transaction) {
        self.transactionId = String(transaction.id)
        self.originalTransactionId = String(transaction.originalID)
        self.productId = transaction.productID
        self.purchaseDate = transaction.purchaseDate
        self.originalPurchaseDate = transaction.purchaseDate
        self.expirationDate = transaction.expirationDate
        self.isUpgraded = transaction.isUpgraded
        self.revocationDate = transaction.revocationDate

        if let reason = transaction.revocationReason {
            switch reason {
            case .developerIssue:
                self.revocationReason = "developerIssue"
            case .other:
                self.revocationReason = "other"
            default:
                self.revocationReason = "unknown"
            }
        } else {
            self.revocationReason = nil
        }

        if let offerType = transaction.offerType {
            switch offerType {
            case .introductory:
                self.isIntroOffer = true
            case .promotional:
                self.isIntroOffer = false
            case .code:
                self.isIntroOffer = false
            default:
                self.isIntroOffer = false
            }
        } else {
            self.isIntroOffer = false
        }

        switch transaction.ownershipType {
        case .purchased:
            self.ownershipType = "purchased"
        case .familyShared:
            self.ownershipType = "familyShared"
        default:
            self.ownershipType = "unknown"
        }

        super.init()
    }
}

@available(iOS 15.0, *)
@objc public class PaymentSubscriptionStatus: NSObject {
    @objc public let productId: String
    @objc public let renewalState: String
    @objc public let expirationDate: Date?
    @objc public let isAutoRenewEnabled: Bool
    @objc public let isInBillingRetry: Bool
    @objc public let isInGracePeriod: Bool
    @objc public let transactionId: String?
    @objc public let willAutoRenewProductId: String?

    public init(
        productId: String,
        renewalState: String,
        expirationDate: Date?,
        isAutoRenewEnabled: Bool,
        isInBillingRetry: Bool,
        isInGracePeriod: Bool,
        transactionId: String?,
        willAutoRenewProductId: String?
    ) {
        self.productId = productId
        self.renewalState = renewalState
        self.expirationDate = expirationDate
        self.isAutoRenewEnabled = isAutoRenewEnabled
        self.isInBillingRetry = isInBillingRetry
        self.isInGracePeriod = isInGracePeriod
        self.transactionId = transactionId
        self.willAutoRenewProductId = willAutoRenewProductId
        super.init()
    }
}

@available(iOS 15.0, *)
@objc public class PaymentManager: NSObject {
    @objc public static let shared: PaymentManager = PaymentManager()
    @objc public weak var delegate: PaymentManagerDelegate?

    private var products: [String: Product] = [:]
    private var transactionListener: Task<Void, Error>?

    private override init() {
        super.init()
        startTransactionListener()
    }

    deinit {
        transactionListener?.cancel()
    }

    // MARK: - Public Methods

    @objc public func requestProducts(productIds: [String], completion: @escaping (Bool, String?) -> Void) {
        Task {
            do {
                let storeProducts: [Product] = try await Product.products(for: Set(productIds))

                await MainActor.run {
                    for product: Product in storeProducts {
                        self.products[product.id] = product
                    }

                    let paymentProducts: [PaymentProduct] = storeProducts.map { PaymentProduct(product: $0) }
                    self.delegate?.paymentManagerDidUpdateProducts?(paymentProducts)
                    completion(true, nil)
                }
            } catch {
                await MainActor.run {
                    completion(false, error.localizedDescription)
                }
            }
        }
    }

    @objc public func purchaseProduct(productId: String, appAccountToken: UUID? = nil, completion: @escaping (Bool, String?) -> Void) {
        guard let product = products[productId] else {
            completion(false, "Product not found: \(productId)")
            return
        }

        Task {
            do {
                var options: Set<Product.PurchaseOption> = []
                if let token = appAccountToken {
                    options.insert(.appAccountToken(token))
                }

                let result: Product.PurchaseResult = try await product.purchase(options: options)

                switch result {
                case .success(let verification):
                    switch verification {
                    case .verified(let transaction):
                        let paymentTransaction = PaymentTransaction(transaction: transaction)
                        await MainActor.run {
                            self.delegate?.paymentManagerDidFinishPurchase?(productId, transaction: paymentTransaction)
                            completion(true, nil)
                        }
                        await transaction.finish()

                    case .unverified(_, let error):
                        await MainActor.run {
                            self.delegate?.paymentManagerDidFailPurchase?(productId, error: "Unverified transaction: \(error.localizedDescription)")
                            completion(false, "Unverified transaction")
                        }
                    }

                case .userCancelled:
                    await MainActor.run {
                        self.delegate?.paymentManagerDidFailPurchase?(productId, error: "User cancelled")
                        completion(false, "User cancelled")
                    }

                case .pending:
                    await MainActor.run {
                        completion(false, "Purchase pending")
                    }

                @unknown default:
                    await MainActor.run {
                        completion(false, "Unknown result")
                    }
                }
            } catch {
                await MainActor.run {
                    self.delegate?.paymentManagerDidFailPurchase?(productId, error: error.localizedDescription)
                    completion(false, error.localizedDescription)
                }
            }
        }
    }

    @objc public func restorePurchases(completion: @escaping (Bool, String?) -> Void) {
        Task {
            do {
                try await AppStore.sync()

                let restoredTransactions = await collectCurrentEntitlements()

                await MainActor.run {
                    self.delegate?.paymentManagerDidRestorePurchases?(restoredTransactions)
                    completion(true, nil)
                }
            } catch {
                await MainActor.run {
                    completion(false, error.localizedDescription)
                }
            }
        }
    }

    @objc public func getProduct(productId: String) -> PaymentProduct? {
        guard let product = products[productId] else { return nil }
        return PaymentProduct(product: product)
    }

    @objc public func getAllProducts() -> [PaymentProduct] {
        return products.values.map { PaymentProduct(product: $0) }
    }

    @objc public func checkPurchaseStatus(productId: String, completion: @escaping (Bool, PaymentTransaction?) -> Void) {
        Task {
            let foundTransaction = await findCurrentEntitlement(for: productId)

            await MainActor.run {
                if let transaction = foundTransaction {
                    completion(true, transaction)
                } else {
                    completion(false, nil)
                }
            }
        }
    }

    @objc public func getSubscriptionStatus(productId: String, completion: @escaping (PaymentSubscriptionStatus?) -> Void) {
        Task {
            let status = await loadSubscriptionStatus(productId: productId)

            await MainActor.run {
                completion(status)
            }
        }
    }

    @objc public func getAllSubscriptionStatuses(completion: @escaping ([PaymentSubscriptionStatus]) -> Void) {
        Task {
            var results: [PaymentSubscriptionStatus] = []

            for (_, product) in products {
                guard product.type == .autoRenewable else { continue }

                if let status = await loadSubscriptionStatus(productId: product.id) {
                    results.append(status)
                }
            }

            await MainActor.run {
                completion(results)
            }
        }
    }

    // MARK: - Private Methods

    private func collectCurrentEntitlements() async -> [PaymentTransaction] {
        var transactions: [PaymentTransaction] = []

        for await result in Transaction.currentEntitlements {
            switch result {
            case .verified(let transaction):
                if transaction.revocationDate == nil {
                    transactions.append(PaymentTransaction(transaction: transaction))
                }
            case .unverified(_, _):
                continue
            }
        }

        return transactions
    }

    private func findCurrentEntitlement(for productId: String) async -> PaymentTransaction? {
        for await result in Transaction.currentEntitlements {
            switch result {
            case .verified(let transaction):
                if transaction.productID == productId && transaction.revocationDate == nil {
                    return PaymentTransaction(transaction: transaction)
                }
            case .unverified(_, _):
                continue
            }
        }

        return nil
    }

    private func loadSubscriptionStatus(productId: String) async -> PaymentSubscriptionStatus? {
        guard let product = products[productId] else { return nil }
        guard product.type == .autoRenewable else { return nil }
        guard let subscription = product.subscription else { return nil }

        do {
            let statuses = try await subscription.status
            guard let status = statuses.first else { return nil }

            let renewalState = mapRenewalState(status.state)

            let verifiedTransaction: Transaction?
            switch status.transaction {
            case .verified(let transaction):
                verifiedTransaction = transaction
            case .unverified(_, _):
                verifiedTransaction = nil
            }

            let verifiedRenewalInfo: Product.SubscriptionInfo.RenewalInfo?
            switch status.renewalInfo {
            case .verified(let renewalInfo):
                verifiedRenewalInfo = renewalInfo
            case .unverified(_, _):
                verifiedRenewalInfo = nil
            }

            let expirationDate = verifiedTransaction?.expirationDate
            let transactionId = verifiedTransaction.map { String($0.id) }
            let isAutoRenewEnabled = verifiedRenewalInfo?.willAutoRenew ?? false
            let nextProductId = verifiedRenewalInfo?.currentProductID

            return PaymentSubscriptionStatus(
                productId: productId,
                renewalState: renewalState,
                expirationDate: expirationDate,
                isAutoRenewEnabled: isAutoRenewEnabled,
                isInBillingRetry: status.state == .inBillingRetryPeriod,
                isInGracePeriod: status.state == .inGracePeriod,
                transactionId: transactionId,
                willAutoRenewProductId: nextProductId
            )
        } catch {
            return nil
        }
    }

    private func mapRenewalState(_ state: Product.SubscriptionInfo.RenewalState) -> String {
        switch state {
        case .subscribed:
            return "subscribed"
        case .expired:
            return "expired"
        case .revoked:
            return "revoked"
        case .inGracePeriod:
            return "gracePeriod"
        case .inBillingRetryPeriod:
            return "billingRetry"
        default:
            return "unknown"
        }
    }

    private func startTransactionListener() {
        transactionListener = Task(priority: .background) {
            for await result in Transaction.updates {
                switch result {
                case .verified(let transaction):
                    let paymentTransaction = PaymentTransaction(transaction: transaction)
                    await MainActor.run {
                        self.delegate?.paymentManagerDidFinishPurchase?(transaction.productID, transaction: paymentTransaction)
                    }
                    await transaction.finish()

                case .unverified(_, let error):
                    await MainActor.run {
                        self.delegate?.paymentManagerDidFailPurchase?("unknown", error: "Unverified transaction: \(error.localizedDescription)")
                    }
                }
            }
        }
    }
}
