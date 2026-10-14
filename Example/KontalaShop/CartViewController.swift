import Combine
import Kontala
import UIKit

/// The basket, and a declared begin checkout, disabled while it is empty.
final class CartViewController: UIViewController, KontalaScreen {
    var kontalaScreenName: String? { "/cart" }
    var kontalaPageType: KontalaPageType? { .cart }

    private let lines = UILabel()
    private let checkout = UIButton(configuration: .filled())
    private var watching: AnyCancellable?

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Cart"
        navigationItem.largeTitleDisplayMode = .never
        view.backgroundColor = .systemBackground
        lines.numberOfLines = 0
        lines.font = .preferredFont(forTextStyle: .body)
        checkout.configuration?.title = "Checkout"
        checkout.kontalaEvent = .beginCheckout
        checkout.addTarget(self, action: #selector(begin), for: .touchUpInside)
        let stack = UIStackView(arrangedSubviews: [lines, checkout])
        stack.axis = .vertical
        stack.spacing = 24
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 24),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
        ])
        watching = Shop.shared.$lines.sink { [weak self] _ in DispatchQueue.main.async { self?.show() } }
    }

    private func show() {
        let shop = Shop.shared
        lines.text =
            shop.lines.isEmpty
            ? "Your cart is empty"
            : shop.lines.map { "\($0.name)  \(price($0.price))" }.joined(separator: "\n")
                + "\n\nTotal \(price(shop.total))"
        checkout.isEnabled = !shop.lines.isEmpty
    }

    @objc private func begin() { push(CheckoutView(navigator: Navigator(navigationController)), title: "Checkout") }
}
