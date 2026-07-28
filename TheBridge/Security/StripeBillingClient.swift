import CryptoKit
import Foundation

public enum StripeMutationState: String, Sendable, Equatable {
    case succeeded
    case failedDefinitively
    case indeterminateExternalEffect
}

public struct StripeMutationReceipt<Value: Sendable>: Sendable {
    public let state: StripeMutationState
    public let value: Value?
    public let error: StripeError?
    public let evidence: StripeRequestEvidence

    public init(
        state: StripeMutationState,
        value: Value?,
        error: StripeError?,
        evidence: StripeRequestEvidence
    ) {
        self.state = state
        self.value = value
        self.error = error
        self.evidence = evidence
    }
}

public struct StripeCustomer: Sendable, Equatable {
    public let id: String
    public let email: String?
    public let name: String?
    public let metadata: [String: String]

    public init(id: String, email: String?, name: String?, metadata: [String: String]) {
        self.id = id
        self.email = email
        self.name = name
        self.metadata = metadata
    }
}

public enum StripeCustomerMatch: Sendable, Equatable {
    case zero
    case one(StripeCustomer)
    case multiple([StripeCustomer])
}

public struct StripeInvoice: Sendable, Equatable {
    public let id: String
    public let customerID: String
    public let amountDue: Int
    public let amountPaid: Int
    public let currency: String
    public let status: String
    public let hostedInvoiceURL: String?
    public let invoicePDFURL: String?
    public let planID: String?
    public let created: Int
    public let metadata: [String: String]

    public init(
        id: String,
        customerID: String,
        amountDue: Int,
        amountPaid: Int,
        currency: String,
        status: String,
        hostedInvoiceURL: String?,
        invoicePDFURL: String?,
        planID: String?,
        created: Int,
        metadata: [String: String]
    ) {
        self.id = id
        self.customerID = customerID
        self.amountDue = amountDue
        self.amountPaid = amountPaid
        self.currency = currency
        self.status = status
        self.hostedInvoiceURL = hostedInvoiceURL
        self.invoicePDFURL = invoicePDFURL
        self.planID = planID
        self.created = created
        self.metadata = metadata
    }
}

public struct StripeInvoiceItem: Sendable, Equatable {
    public let id: String
    public let invoiceID: String?
    public let amount: Int
    public let currency: String
    public let quantity: Int
    public let unitAmount: Int?
    public let description: String?
    public let metadata: [String: String]

    public init(
        id: String,
        invoiceID: String?,
        amount: Int,
        currency: String,
        quantity: Int,
        unitAmount: Int?,
        description: String?,
        metadata: [String: String]
    ) {
        self.id = id
        self.invoiceID = invoiceID
        self.amount = amount
        self.currency = currency
        self.quantity = quantity
        self.unitAmount = unitAmount
        self.description = description
        self.metadata = metadata
    }
}

public struct StripeEvent: Sendable, Equatable {
    public let id: String
    public let type: String
    public let objectID: String
    public let created: Int

    public init(id: String, type: String, objectID: String, created: Int) {
        self.id = id
        self.type = type
        self.objectID = objectID
        self.created = created
    }
}

public enum StripeSendReconciliation: Sendable, Equatable {
    case proven(event: StripeEvent, evidence: StripeRequestEvidence)
    case notProven
}

public struct StripeCompletedOperation: Sendable, Equatable {
    public let operation: String
    public let objectID: String?
    public let evidence: StripeRequestEvidence

    public init(operation: String, objectID: String?, evidence: StripeRequestEvidence) {
        self.operation = operation
        self.objectID = objectID
        self.evidence = evidence
    }
}

public struct StripeInvoiceWorkflowReceipt: Sendable {
    public let state: StripeMutationState
    public let customerID: String
    public let invoiceID: String?
    public let invoiceItemID: String?
    public let completedOperations: [StripeCompletedOperation]
    public let failedOperation: String?
    public let error: StripeError?
    public let latestInvoice: StripeInvoice?

    public init(
        state: StripeMutationState,
        customerID: String,
        invoiceID: String?,
        invoiceItemID: String?,
        completedOperations: [StripeCompletedOperation],
        failedOperation: String?,
        error: StripeError?,
        latestInvoice: StripeInvoice?
    ) {
        self.state = state
        self.customerID = customerID
        self.invoiceID = invoiceID
        self.invoiceItemID = invoiceItemID
        self.completedOperations = completedOperations
        self.failedOperation = failedOperation
        self.error = error
        self.latestInvoice = latestInvoice
    }
}

public extension StripeClient {
    static let operationMetadataKey = "bridge_operation_id"
    static let planMetadataKey = "plan_id"

    static func deterministicIdempotencyKey(
        operation: String,
        intentID: String,
        targetID: String? = nil,
        fields: [String: String]
    ) -> String {
        let canonicalFields = fields
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: "\n")
        let canonical = [operation, intentID, targetID ?? "", canonicalFields].joined(separator: "\n---\n")
        let digest = SHA256.hash(data: Data(canonical.utf8))
        let hash = digest.map { String(format: "%02x", $0) }.joined()
        let operationSlug = operation
            .lowercased()
            .map { $0.isLetter || $0.isNumber ? $0 : "-" }
            .reduce(into: "") { $0.append($1) }
        return "bridge-\(operationSlug)-\(hash.prefix(48))"
    }

    func listCustomers(email: String) async throws -> StripeCustomerMatch {
        let normalized = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            throw StripeError.invalidInput("customer email is required")
        }
        let request = try authorizedRequest(
            method: "GET",
            path: "customers",
            queryItems: [URLQueryItem(name: "email", value: normalized), URLQueryItem(name: "limit", value: "100")]
        )
        let response = try await readResponse(request, operation: "customer.list")
        let customers = try Self.parseCustomerList(data: response.data)
        switch customers.count {
        case 0: return .zero
        case 1: return .one(customers[0])
        default: return .multiple(customers)
        }
    }

    func retrieveCustomer(id: String) async throws -> StripeCustomer {
        let customerID = try Self.requireValue(id, field: "customer id")
        let request = try authorizedRequest(method: "GET", endpoint: "customers/\(customerID)")
        let response = try await readResponse(request, operation: "customer.retrieve")
        return try Self.parseCustomer(data: response.data)
    }

    func createCustomer(
        email: String,
        name: String?,
        intentID: String,
        metadata: [String: String] = [:]
    ) async -> StripeMutationReceipt<StripeCustomer> {
        let operation = "customer.create"
        do {
            let normalizedEmail = try Self.requireValue(email, field: "customer email")
            let normalizedIntent = try Self.requireValue(intentID, field: "intent id")
            var fields = metadata.reduce(into: [String: String]()) { result, pair in
                result["metadata[\(pair.key)]"] = pair.value
            }
            fields["email"] = normalizedEmail
            if let name = name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
                fields["name"] = name
            }
            fields["metadata[\(Self.operationMetadataKey)]"] = normalizedIntent
            let key = Self.deterministicIdempotencyKey(
                operation: operation,
                intentID: normalizedIntent,
                fields: fields
            )
            return await executeMutation(
                operation: operation,
                path: "customers",
                idempotencyKey: key,
                fields: fields,
                parse: Self.parseCustomer(data:)
            )
        } catch let error as StripeError {
            return Self.localFailure(operation: operation, method: "POST", path: "/v1/customers", error: error)
        } catch {
            return Self.localFailure(operation: operation, method: "POST", path: "/v1/customers", error: .processingError(error.localizedDescription))
        }
    }

    func reconcileCustomerCreate(email: String, intentID: String) async throws -> StripeCustomerMatch {
        let match = try await listCustomers(email: email)
        let candidates: [StripeCustomer]
        switch match {
        case .zero: candidates = []
        case .one(let customer): candidates = [customer]
        case .multiple(let customers): candidates = customers
        }
        let filtered = candidates.filter { $0.metadata[Self.operationMetadataKey] == intentID }
        switch filtered.count {
        case 0: return .zero
        case 1: return .one(filtered[0])
        default: return .multiple(filtered)
        }
    }

    func createInvoice(
        customerID: String,
        planID: String,
        intentID: String,
        daysUntilDue: Int = 30,
        metadata: [String: String] = [:]
    ) async -> StripeMutationReceipt<StripeInvoice> {
        let operation = "invoice.create"
        do {
            let customer = try Self.requireValue(customerID, field: "customer id")
            let plan = try Self.requireValue(planID, field: "plan id")
            let intent = try Self.requireValue(intentID, field: "intent id")
            guard daysUntilDue > 0 else {
                throw StripeError.invalidInput("days until due must be greater than zero")
            }
            var fields = metadata.reduce(into: [String: String]()) { result, pair in
                result["metadata[\(pair.key)]"] = pair.value
            }
            fields["customer"] = customer
            fields["collection_method"] = "send_invoice"
            fields["days_until_due"] = String(daysUntilDue)
            fields["metadata[\(Self.planMetadataKey)]"] = plan
            fields["metadata[\(Self.operationMetadataKey)]"] = intent
            let key = Self.deterministicIdempotencyKey(
                operation: operation,
                intentID: intent,
                targetID: customer,
                fields: fields
            )
            return await executeMutation(
                operation: operation,
                path: "invoices",
                idempotencyKey: key,
                fields: fields,
                parse: Self.parseInvoice(data:)
            )
        } catch let error as StripeError {
            return Self.localFailure(operation: operation, method: "POST", path: "/v1/invoices", error: error)
        } catch {
            return Self.localFailure(operation: operation, method: "POST", path: "/v1/invoices", error: .processingError(error.localizedDescription))
        }
    }

    func listInvoices(customerID: String) async throws -> [StripeInvoice] {
        let customer = try Self.requireValue(customerID, field: "customer id")
        let request = try authorizedRequest(
            method: "GET",
            path: "invoices",
            queryItems: [URLQueryItem(name: "customer", value: customer), URLQueryItem(name: "limit", value: "100")]
        )
        let response = try await readResponse(request, operation: "invoice.list")
        return try Self.parseInvoiceList(data: response.data)
    }

    func reconcileInvoiceCreate(customerID: String, intentID: String) async throws -> StripeInvoice? {
        let matches = try await listInvoices(customerID: customerID)
            .filter { $0.metadata[Self.operationMetadataKey] == intentID }
        guard matches.count <= 1 else {
            throw StripeError.ambiguousResult(operation: "invoice.create", count: matches.count)
        }
        return matches.first
    }

    func createInvoiceItem(
        invoiceID: String,
        customerID: String,
        planID: String,
        intentID: String,
        quantity: Int = 4,
        unitAmount: Int = 5_000,
        currency: String = "usd",
        description: String,
        metadata: [String: String] = [:]
    ) async -> StripeMutationReceipt<StripeInvoiceItem> {
        let operation = "invoice_item.create"
        do {
            let invoice = try Self.requireValue(invoiceID, field: "invoice id")
            let customer = try Self.requireValue(customerID, field: "customer id")
            let plan = try Self.requireValue(planID, field: "plan id")
            let intent = try Self.requireValue(intentID, field: "intent id")
            let normalizedDescription = try Self.requireValue(description, field: "invoice description")
            guard quantity > 0 else { throw StripeError.invalidInput("quantity must be greater than zero") }
            guard unitAmount > 0 else { throw StripeError.invalidAmount }
            var fields = metadata.reduce(into: [String: String]()) { result, pair in
                result["metadata[\(pair.key)]"] = pair.value
            }
            fields["invoice"] = invoice
            fields["customer"] = customer
            fields["quantity"] = String(quantity)
            fields["unit_amount"] = String(unitAmount)
            fields["currency"] = currency.lowercased()
            fields["description"] = normalizedDescription
            fields["metadata[\(Self.planMetadataKey)]"] = plan
            fields["metadata[\(Self.operationMetadataKey)]"] = intent
            let key = Self.deterministicIdempotencyKey(
                operation: operation,
                intentID: intent,
                targetID: invoice,
                fields: fields
            )
            return await executeMutation(
                operation: operation,
                path: "invoiceitems",
                idempotencyKey: key,
                fields: fields,
                parse: Self.parseInvoiceItem(data:)
            )
        } catch let error as StripeError {
            return Self.localFailure(operation: operation, method: "POST", path: "/v1/invoiceitems", error: error)
        } catch {
            return Self.localFailure(operation: operation, method: "POST", path: "/v1/invoiceitems", error: .processingError(error.localizedDescription))
        }
    }

    func listInvoiceItems(invoiceID: String) async throws -> [StripeInvoiceItem] {
        let invoice = try Self.requireValue(invoiceID, field: "invoice id")
        let request = try authorizedRequest(
            method: "GET",
            path: "invoiceitems",
            queryItems: [URLQueryItem(name: "invoice", value: invoice), URLQueryItem(name: "limit", value: "100")]
        )
        let response = try await readResponse(request, operation: "invoice_item.list")
        return try Self.parseInvoiceItemList(data: response.data)
    }

    func reconcileInvoiceItemCreate(invoiceID: String, intentID: String) async throws -> StripeInvoiceItem? {
        let matches = try await listInvoiceItems(invoiceID: invoiceID)
            .filter { $0.metadata[Self.operationMetadataKey] == intentID }
        guard matches.count <= 1 else {
            throw StripeError.ambiguousResult(operation: "invoice_item.create", count: matches.count)
        }
        return matches.first
    }

    func retrieveInvoice(id: String) async throws -> StripeInvoice {
        let invoiceID = try Self.requireValue(id, field: "invoice id")
        let request = try authorizedRequest(method: "GET", endpoint: "invoices/\(invoiceID)")
        let response = try await readResponse(request, operation: "invoice.retrieve")
        return try Self.parseInvoice(data: response.data)
    }

    func finalizeInvoice(id: String, intentID: String) async -> StripeMutationReceipt<StripeInvoice> {
        await invoiceTransition(operation: "invoice.finalize", id: id, intentID: intentID, suffix: "finalize")
    }

    func sendInvoice(id: String, intentID: String) async -> StripeMutationReceipt<StripeInvoice> {
        await invoiceTransition(operation: "invoice.send", id: id, intentID: intentID, suffix: "send")
    }

    func voidInvoice(id: String, intentID: String) async -> StripeMutationReceipt<StripeInvoice> {
        let operation = "invoice.void"
        do {
            let invoiceID = try Self.requireValue(id, field: "invoice id")
            let intent = try Self.requireValue(intentID, field: "intent id")
            let current = try await retrieveInvoice(id: invoiceID)
            if current.status == "paid" || current.amountPaid > 0 {
                return Self.localFailure(
                    operation: operation,
                    method: "POST",
                    path: "/v1/invoices/\(invoiceID)/void",
                    error: .illegalInvoiceState(operation: "void", status: current.status)
                )
            }
            let fields: [String: String] = [:]
            let key = Self.deterministicIdempotencyKey(
                operation: operation,
                intentID: intent,
                targetID: invoiceID,
                fields: fields
            )
            return await executeMutation(
                operation: operation,
                path: "invoices/\(invoiceID)/void",
                idempotencyKey: key,
                fields: fields,
                parse: Self.parseInvoice(data:)
            )
        } catch let error as StripeError {
            return Self.localFailure(operation: operation, method: "POST", path: "/v1/invoices/\(id)/void", error: error)
        } catch {
            return Self.localFailure(operation: operation, method: "POST", path: "/v1/invoices/\(id)/void", error: .processingError(error.localizedDescription))
        }
    }

    func reconcileInvoiceSend(
        invoiceID: String,
        createdAtOrAfter: Int,
        maxPages: Int = 10
    ) async throws -> StripeSendReconciliation {
        let invoice = try Self.requireValue(invoiceID, field: "invoice id")
        guard createdAtOrAfter > 0 else {
            throw StripeError.invalidInput("event search start must be positive")
        }
        guard (1...100).contains(maxPages) else {
            throw StripeError.invalidInput("max pages must be between 1 and 100")
        }

        var startingAfter: String?
        for _ in 0..<maxPages {
            var queryItems = [
                URLQueryItem(name: "type", value: "invoice.sent"),
                URLQueryItem(name: "created[gte]", value: String(createdAtOrAfter)),
                URLQueryItem(name: "limit", value: "100")
            ]
            if let startingAfter {
                queryItems.append(URLQueryItem(name: "starting_after", value: startingAfter))
            }
            let request = try authorizedRequest(method: "GET", path: "events", queryItems: queryItems)
            let response = try await readResponse(request, operation: "invoice.sent.reconcile")
            let page = try Self.parseEventPage(data: response.data)
            if let event = page.events.first(where: { $0.objectID == invoice }) {
                return .proven(event: event, evidence: response.evidence)
            }
            guard page.hasMore, let last = page.events.last else {
                return .notProven
            }
            startingAfter = last.id
        }
        return .notProven
    }

    func createFourHourInvoice(
        customerID: String,
        planID: String,
        intentID: String,
        description: String,
        daysUntilDue: Int = 30,
        metadata: [String: String] = [:]
    ) async -> StripeInvoiceWorkflowReceipt {
        var completed: [StripeCompletedOperation] = []
        var invoiceID: String?
        var invoiceItemID: String?
        var latestInvoice: StripeInvoice?

        let invoiceResult = await createInvoice(
            customerID: customerID,
            planID: planID,
            intentID: intentID,
            daysUntilDue: daysUntilDue,
            metadata: metadata
        )
        guard invoiceResult.state == .succeeded, let invoice = invoiceResult.value else {
            return workflowFailure(
                customerID: customerID,
                invoiceID: nil,
                invoiceItemID: nil,
                completed: completed,
                operation: "invoice.create",
                resultState: invoiceResult.state,
                error: invoiceResult.error,
                latestInvoice: nil
            )
        }
        invoiceID = invoice.id
        latestInvoice = invoice
        completed.append(.init(operation: "invoice.create", objectID: invoice.id, evidence: invoiceResult.evidence))

        let itemResult = await createInvoiceItem(
            invoiceID: invoice.id,
            customerID: customerID,
            planID: planID,
            intentID: intentID,
            quantity: 4,
            unitAmount: 5_000,
            currency: "usd",
            description: description,
            metadata: metadata
        )
        guard itemResult.state == .succeeded, let item = itemResult.value else {
            return workflowFailure(
                customerID: customerID,
                invoiceID: invoiceID,
                invoiceItemID: nil,
                completed: completed,
                operation: "invoice_item.create",
                resultState: itemResult.state,
                error: itemResult.error,
                latestInvoice: latestInvoice
            )
        }
        invoiceItemID = item.id
        completed.append(.init(operation: "invoice_item.create", objectID: item.id, evidence: itemResult.evidence))

        let finalizeResult = await finalizeInvoice(id: invoice.id, intentID: intentID)
        guard finalizeResult.state == .succeeded, let finalized = finalizeResult.value else {
            return workflowFailure(
                customerID: customerID,
                invoiceID: invoiceID,
                invoiceItemID: invoiceItemID,
                completed: completed,
                operation: "invoice.finalize",
                resultState: finalizeResult.state,
                error: finalizeResult.error,
                latestInvoice: latestInvoice
            )
        }
        latestInvoice = finalized
        completed.append(.init(operation: "invoice.finalize", objectID: finalized.id, evidence: finalizeResult.evidence))

        let sendResult = await sendInvoice(id: invoice.id, intentID: intentID)
        if sendResult.state == .succeeded, let sent = sendResult.value {
            latestInvoice = sent
            completed.append(.init(operation: "invoice.send", objectID: sent.id, evidence: sendResult.evidence))
            return StripeInvoiceWorkflowReceipt(
                state: .succeeded,
                customerID: customerID,
                invoiceID: invoiceID,
                invoiceItemID: invoiceItemID,
                completedOperations: completed,
                failedOperation: nil,
                error: nil,
                latestInvoice: latestInvoice
            )
        }

        if sendResult.state == .indeterminateExternalEffect {
            do {
                let reconciliation = try await reconcileInvoiceSend(
                    invoiceID: invoice.id,
                    createdAtOrAfter: max(1, invoice.created - 300)
                )
                if case .proven(let event, let evidence) = reconciliation {
                    completed.append(.init(operation: "invoice.send.reconciled", objectID: event.objectID, evidence: evidence))
                    return StripeInvoiceWorkflowReceipt(
                        state: .succeeded,
                        customerID: customerID,
                        invoiceID: invoiceID,
                        invoiceItemID: invoiceItemID,
                        completedOperations: completed,
                        failedOperation: nil,
                        error: nil,
                        latestInvoice: latestInvoice
                    )
                }
            } catch {
                // Reconciliation is read-only evidence gathering. Its failure cannot
                // downgrade or upgrade the original indeterminate send outcome.
            }
        }

        return workflowFailure(
            customerID: customerID,
            invoiceID: invoiceID,
            invoiceItemID: invoiceItemID,
            completed: completed,
            operation: "invoice.send",
            resultState: sendResult.state,
            error: sendResult.error,
            latestInvoice: latestInvoice
        )
    }
}

private extension StripeClient {
    struct StripeEventPage {
        let events: [StripeEvent]
        let hasMore: Bool
    }

    func readResponse(_ request: URLRequest, operation: String) async throws -> StripeHTTPResponse {
        do {
            return try await performEvidenceRequest(request, operation: operation)
        } catch let failure as StripeTransportFailure {
            throw failure.error
        }
    }

    func executeMutation<Value: Sendable>(
        operation: String,
        path: String,
        idempotencyKey: String,
        fields: [String: String],
        parse: (Data) throws -> Value
    ) async -> StripeMutationReceipt<Value> {
        do {
            var request = try authorizedRequest(method: "POST", endpoint: path, idempotencyKey: idempotencyKey)
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = Self.formURLEncoded(fields).data(using: .utf8)
            let response = try await performEvidenceRequest(request, operation: operation)
            do {
                let value = try parse(response.data)
                return StripeMutationReceipt(state: .succeeded, value: value, error: nil, evidence: response.evidence)
            } catch let error as StripeError {
                return StripeMutationReceipt(
                    state: .indeterminateExternalEffect,
                    value: nil,
                    error: error,
                    evidence: response.evidence
                )
            } catch {
                return StripeMutationReceipt(
                    state: .indeterminateExternalEffect,
                    value: nil,
                    error: .processingError(error.localizedDescription),
                    evidence: response.evidence
                )
            }
        } catch let failure as StripeTransportFailure {
            let state: StripeMutationState = failure.disposition == .indeterminateExternalEffect
                ? .indeterminateExternalEffect
                : .failedDefinitively
            return StripeMutationReceipt(state: state, value: nil, error: failure.error, evidence: failure.evidence)
        } catch let error as StripeError {
            return Self.localFailure(operation: operation, method: "POST", path: "/v1/\(path)", error: error, idempotencyKey: idempotencyKey)
        } catch {
            return Self.localFailure(
                operation: operation,
                method: "POST",
                path: "/v1/\(path)",
                error: .processingError(error.localizedDescription),
                idempotencyKey: idempotencyKey
            )
        }
    }

    func invoiceTransition(
        operation: String,
        id: String,
        intentID: String,
        suffix: String
    ) async -> StripeMutationReceipt<StripeInvoice> {
        do {
            let invoiceID = try Self.requireValue(id, field: "invoice id")
            let intent = try Self.requireValue(intentID, field: "intent id")
            let fields: [String: String] = [:]
            let key = Self.deterministicIdempotencyKey(
                operation: operation,
                intentID: intent,
                targetID: invoiceID,
                fields: fields
            )
            return await executeMutation(
                operation: operation,
                path: "invoices/\(invoiceID)/\(suffix)",
                idempotencyKey: key,
                fields: fields,
                parse: Self.parseInvoice(data:)
            )
        } catch let error as StripeError {
            return Self.localFailure(operation: operation, method: "POST", path: "/v1/invoices/\(id)/\(suffix)", error: error)
        } catch {
            return Self.localFailure(operation: operation, method: "POST", path: "/v1/invoices/\(id)/\(suffix)", error: .processingError(error.localizedDescription))
        }
    }

    func workflowFailure(
        customerID: String,
        invoiceID: String?,
        invoiceItemID: String?,
        completed: [StripeCompletedOperation],
        operation: String,
        resultState: StripeMutationState,
        error: StripeError?,
        latestInvoice: StripeInvoice?
    ) -> StripeInvoiceWorkflowReceipt {
        StripeInvoiceWorkflowReceipt(
            state: resultState,
            customerID: customerID,
            invoiceID: invoiceID,
            invoiceItemID: invoiceItemID,
            completedOperations: completed,
            failedOperation: operation,
            error: error,
            latestInvoice: latestInvoice
        )
    }

    static func localFailure<Value: Sendable>(
        operation: String,
        method: String,
        path: String,
        error: StripeError,
        idempotencyKey: String? = nil
    ) -> StripeMutationReceipt<Value> {
        StripeMutationReceipt(
            state: .failedDefinitively,
            value: nil,
            error: error,
            evidence: StripeRequestEvidence(
                operation: operation,
                method: method,
                path: path,
                idempotencyKey: idempotencyKey,
                requestAPIVersion: Self.apiVersion,
                statusCode: nil,
                requestID: nil,
                responseAPIVersion: nil
            )
        )
    }

    static func requireValue(_ value: String, field: String) throws -> String {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            throw StripeError.invalidInput("\(field) is required")
        }
        return normalized
    }

    static func parseCustomer(data: Data) throws -> StripeCustomer {
        let json = try jsonObject(data)
        guard let id = json["id"] as? String else { throw StripeError.invalidResponse }
        return StripeCustomer(
            id: id,
            email: json["email"] as? String,
            name: json["name"] as? String,
            metadata: stringDictionary(json["metadata"])
        )
    }

    static func parseCustomerList(data: Data) throws -> [StripeCustomer] {
        let json = try jsonObject(data)
        guard let objects = json["data"] as? [[String: Any]] else { throw StripeError.invalidResponse }
        return try objects.map { object in
            try parseCustomer(data: JSONSerialization.data(withJSONObject: object))
        }
    }

    static func parseInvoice(data: Data) throws -> StripeInvoice {
        let json = try jsonObject(data)
        guard
            let id = json["id"] as? String,
            let customerID = json["customer"] as? String,
            let amountDue = integer(json["amount_due"]),
            let amountPaid = integer(json["amount_paid"]),
            let currency = json["currency"] as? String,
            let status = json["status"] as? String,
            let created = integer(json["created"])
        else {
            throw StripeError.invalidResponse
        }
        let metadata = stringDictionary(json["metadata"])
        return StripeInvoice(
            id: id,
            customerID: customerID,
            amountDue: amountDue,
            amountPaid: amountPaid,
            currency: currency,
            status: status,
            hostedInvoiceURL: json["hosted_invoice_url"] as? String,
            invoicePDFURL: json["invoice_pdf"] as? String,
            planID: metadata[Self.planMetadataKey],
            created: created,
            metadata: metadata
        )
    }

    static func parseInvoiceList(data: Data) throws -> [StripeInvoice] {
        let json = try jsonObject(data)
        guard let objects = json["data"] as? [[String: Any]] else { throw StripeError.invalidResponse }
        return try objects.map { object in
            try parseInvoice(data: JSONSerialization.data(withJSONObject: object))
        }
    }

    static func parseInvoiceItem(data: Data) throws -> StripeInvoiceItem {
        let json = try jsonObject(data)
        guard
            let id = json["id"] as? String,
            let amount = integer(json["amount"]),
            let currency = json["currency"] as? String
        else {
            throw StripeError.invalidResponse
        }
        let quantity = integer(json["quantity"]) ?? 1
        let pricing = json["pricing"] as? [String: Any]
        let unitAmount = integer(json["unit_amount"])
            ?? pricing.flatMap { integer($0["unit_amount_decimal"]) }
        return StripeInvoiceItem(
            id: id,
            invoiceID: json["invoice"] as? String,
            amount: amount,
            currency: currency,
            quantity: quantity,
            unitAmount: unitAmount,
            description: json["description"] as? String,
            metadata: stringDictionary(json["metadata"])
        )
    }

    static func parseInvoiceItemList(data: Data) throws -> [StripeInvoiceItem] {
        let json = try jsonObject(data)
        guard let objects = json["data"] as? [[String: Any]] else { throw StripeError.invalidResponse }
        return try objects.map { object in
            try parseInvoiceItem(data: JSONSerialization.data(withJSONObject: object))
        }
    }

    static func parseEventPage(data: Data) throws -> StripeEventPage {
        let json = try jsonObject(data)
        guard let objects = json["data"] as? [[String: Any]] else { throw StripeError.invalidResponse }
        let events = try objects.map { object -> StripeEvent in
            guard
                let id = object["id"] as? String,
                let type = object["type"] as? String,
                let created = integer(object["created"]),
                let eventData = object["data"] as? [String: Any],
                let stripeObject = eventData["object"] as? [String: Any],
                let objectID = stripeObject["id"] as? String
            else {
                throw StripeError.invalidResponse
            }
            return StripeEvent(id: id, type: type, objectID: objectID, created: created)
        }
        return StripeEventPage(events: events, hasMore: json["has_more"] as? Bool ?? false)
    }

    static func jsonObject(_ data: Data) throws -> [String: Any] {
        do {
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw StripeError.invalidResponse
            }
            return object
        } catch let error as StripeError {
            throw error
        } catch {
            throw StripeError.invalidResponse
        }
    }

    static func stringDictionary(_ value: Any?) -> [String: String] {
        guard let dictionary = value as? [String: Any] else { return [:] }
        return dictionary.reduce(into: [:]) { result, pair in
            if let string = pair.value as? String {
                result[pair.key] = string
            }
        }
    }

    static func integer(_ value: Any?) -> Int? {
        if let int = value as? Int { return int }
        if let number = value as? NSNumber { return number.intValue }
        if let string = value as? String { return Int(string) }
        return nil
    }
}
