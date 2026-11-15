import Foundation

@main
struct ReceiptChecks {
    static func main() async throws {
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            precondition(condition(), message)
            checks += 1
        }

        let dinner = try ReceiptRecognizer.parse(lines: [
            "Neighborhood Kitchen", "Pasta $18.00", "Salad $12.50",
            "Subtotal $30.50", "Sales Tax $2.44", "Total $32.94"
        ])
        check(dinner.merchant == "Neighborhood Kitchen", "Keep the restaurant name")
        check(dinner.items.map(\.amountCents) == [1_800, 1_250], "Keep complete restaurant itemization")
        check(dinner.taxCents == 244 && dinner.totalCents == 3_294, "Keep food, tax and total separate")
        check(dinner.tipCents == 0, "Do not infer a restaurant tip")

        let groceries = try ReceiptRecognizer.parse(lines: [
            "Corner Market", "Apples 3.27", "Coffee beans 12.99 F", "Bread 6.50",
            "Subtotal 22.76", "State tax 0.40", "Local tax 0.17", "Total 23.33",
            "Visa 23.33", "Change 0.00"
        ])
        check(groceries.items.map(\.amountCents) == [327, 1_299, 650], "Parse grocery decimals and tax flags")
        check(groceries.taxCents == 57, "Accumulate separate tax components")
        check(groceries.totalCents == 2_333 && groceries.items.count == 3, "Payment and change are not items")

        // Synthetic order-summary fixture: product prices may occupy their own
        // OCR line while summary labels and amounts are correctly joined.
        let orderLines = [
            "Order summary", "Ready for pickup", "55-inch television",
            "$699.99", "Sold by Example Store", "Subtotal $699.99",
            "Store Pickup FREE", "Est. Sales Tax $45.50", "Total $745.49",
            "You’re saving $700.00 today", "Rewards earned $7.00"
        ]
        let order = try ReceiptRecognizer.parse(lines: orderLines)
        check(order.items.count == 1, "Missing itemization creates one aggregate subtotal")
        check(order.items.first?.name == "Receipt subtotal", "Aggregate fallback is clearly labeled")
        check(order.items.first?.amountCents == 69_999, "Standalone item price does not hide labeled subtotal")
        check(order.taxCents == 4_550, "Estimated sales tax is tax, never a purchasable item")
        check(order.totalCents == 74_549, "Preserve the explicitly printed total")
        check(order.items.reduce(0) { $0 + $1.amountCents } + order.taxCents == 74_549,
              "Editable draft agrees with the printed total")
        check(order.tipCents == 0, "Retail order does not invent a printed tip")
        check(order.rawText.contains("$699.99") && order.rawText.contains("saving"),
              "Preserve original OCR text for review")

        for label in ["Est. Sales Tax", "Est Sales Tax", "Estimated Sales Tax", "EST. TAX", "Estimated tax", "Est. State Tax"] {
            let receipt = try ReceiptRecognizer.parse(lines: ["Subtotal $100.00", "\(label) $6.50", "Total $106.50"])
            check(receipt.taxCents == 650 && receipt.items.map(\.amountCents) == [10_000],
                  "Recognize estimated tax label: \(label)")
        }

        let noTotal = try ReceiptRecognizer.parse(lines: ["Order summary", "Subtotal $699.99", "Estimated Sales Tax $45.50"])
        check(noTotal.items.map(\.amountCents) == [69_999] && noTotal.taxCents == 4_550,
              "Subtotal-only receipt still provides an editable base and separate tax")
        check(noTotal.totalCents == nil, "Do not invent a printed total when none was detected")

        let promotional = try ReceiptRecognizer.parse(lines: [
            "Store order", "Subtotal $100.00", "Tax $6.50", "Total $106.50",
            "Savings $700.00", "Saving $700.00", "Reward $200.00", "Rewards $200.00",
            "Coupon $25.00", "Discount -$10.00"
        ])
        check(promotional.items.map(\.amountCents) == [10_000], "Savings and reward amounts never become items")
        check(promotional.totalCents == 10_650, "The largest visible amount is not necessarily the total")

        let partial = try ReceiptRecognizer.parse(lines: [
            "Grocery receipt", "Bread $6.50", "Subtotal $20.00", "Tax $1.30", "Total $21.30"
        ])
        check(partial.items.count == 1 && partial.items.first?.name == "Bread" && partial.items.first?.amountCents == 650,
              "Do not replace partially recognized itemization with invented detail")
        check(partial.totalCents == 2_130 && partial.taxCents == 130,
              "Keep printed total so the draft can require mismatch review")
        check(partial.items.reduce(0) { $0 + $1.amountCents } + partial.taxCents != partial.totalCents,
              "Partial extraction remains visibly unreconciled")

        let gratuity = try ReceiptRecognizer.parse(lines: [
            "Dinner", "Meal $40.00", "Tax $4.00", "Gratuity $8.00", "Total $52.00",
            "Suggested tip 15% $6.00", "Suggested tip 20% $8.00", "Recommended tip $10.00"
        ])
        check(gratuity.items.map(\.amountCents) == [4_000], "Suggested tips are not line items")
        check(gratuity.tipCents == 800 && gratuity.taxCents == 400 && gratuity.totalCents == 5_200,
              "Only already-included gratuity contributes to scanned tip")

        let thousands = try ReceiptRecognizer.parse(lines: ["Furniture $1,299.99", "Tax $84.50", "Total $1,384.49"])
        check(thousands.items.first?.amountCents == 129_999 && thousands.totalCents == 138_449,
              "Comma-separated prices retain all digits")

        do {
            _ = try ReceiptRecognizer.parse(lines: [" ", "\n"])
            preconditionFailure("Empty OCR must fail instead of making a zero-dollar receipt")
        } catch ReceiptScanError.noText { checks += 1 }
        for lines in [["Store order", "Order number 69999"], ["Est. Sales Tax $45.50"], ["Savings $700.00"]] {
            do {
                _ = try ReceiptRecognizer.parse(lines: lines)
                preconditionFailure("Tax, promotions and identifiers alone are not a bill")
            } catch ReceiptScanError.noAmounts { checks += 1 }
        }

        // Optional local-only native OCR regression. No image is bundled in the
        // repository, and the supplied image is never modified or uploaded.
        if let index = CommandLine.arguments.firstIndex(of: "--image") {
            guard CommandLine.arguments.indices.contains(index + 1) else {
                preconditionFailure("Provide a local image path after --image")
            }
            let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[index + 1]))
            let scanned = try await ReceiptRecognizer.recognize(imageData: data)
            check(scanned.items.count == 1 && scanned.items.first?.amountCents == 69_999,
                  "Native OCR recovers the order subtotal from the supplied image")
            check(scanned.taxCents == 4_550 && scanned.totalCents == 74_549,
                  "Native OCR keeps the supplied image’s tax and total separate")
            check(scanned.items.reduce(0) { $0 + $1.amountCents } + scanned.taxCents == scanned.totalCents,
                  "Native OCR produces a reconciled editable draft")
        }

        print("Passed \(checks) receipt checks.")
    }
}
