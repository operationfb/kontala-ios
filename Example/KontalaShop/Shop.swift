import Foundation
import SwiftUI
import UIKit

struct Product: Identifiable, Hashable {
    let id: String
    let name: String
    let price: Double
    let colour: UIColor
}

/// The shop's catalogue and its basket, in memory.
final class Shop: ObservableObject {
    static let shared = Shop()

    static let products = [
        Product(id: "42", name: "Linen shirt", price: 79, colour: .systemTeal),
        Product(id: "43", name: "Wool jumper", price: 119, colour: .systemIndigo),
        Product(id: "44", name: "Canvas tote", price: 35, colour: .systemOrange),
        Product(id: "45", name: "Leather belt", price: 49, colour: .brown),
        Product(id: "46", name: "Cotton scarf", price: 29, colour: .systemPink),
        Product(id: "47", name: "Rain jacket", price: 159, colour: .systemGreen),
    ]

    static func product(_ id: String) -> Product? { products.first { $0.id == id } }

    @Published private(set) var lines: [Product] = []

    var total: Double { lines.reduce(0) { $0 + $1.price } }

    func add(_ p: Product) { lines.append(p) }

    func empty() { lines.removeAll() }

    func count(of p: Product) -> Int { lines.filter { $0 == p }.count }
}

func price(_ value: Double) -> String { String(format: "£%.2f", value) }

extension UIViewController {
    /// Shows a SwiftUI screen, titled as the navigation bar shows it.
    func push<V: View>(_ view: V, title: String) {
        let host = UIHostingController(rootView: view.environmentObject(Shop.shared))
        host.title = title
        navigationController?.pushViewController(host, animated: true)
    }
}

/// What a SwiftUI screen asks of the UIKit navigation it is shown in.
final class Navigator: ObservableObject {
    weak var navigation: UINavigationController?

    init(_ navigation: UINavigationController?) { self.navigation = navigation }

    func open(_ p: Product) { navigation?.pushViewController(ProductViewController(product: p), animated: true) }

    func back() { navigation?.popToRootViewController(animated: true) }
}
