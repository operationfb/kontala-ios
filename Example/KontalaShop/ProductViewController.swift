import Kontala
import UIKit

/// A product: declared a product page with its data, a declared add to cart that says on the page how many are in the
/// cart, a photo that loads before the page calls `Kontala.screenReady()`, a disabled button, one nothing answers, one
/// that answers late, a size guide that throws, and the way to Delivery and returns.
final class ProductViewController: UIViewController, KontalaScreen {
    let product: Product

    var kontalaScreenName: String? { "/product/\(product.id)" }
    var kontalaPageType: KontalaPageType? { .productDetail }
    var kontalaScreenProperties: [String: Any]? {
        ["product": ["id": product.id, "name": product.name, "price": product.price] as [String: Any]]
    }

    private let page = UIScrollView()
    private let stack = UIStackView()
    private let photo = UIImageView()
    private let inCart = UILabel()
    private let delivery = UILabel()

    init(product: Product) {
        self.product = product
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("not from a storyboard") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = product.name
        navigationItem.largeTitleDisplayMode = .never
        view.backgroundColor = .systemBackground
        page.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(page)
        stack.axis = .vertical
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        page.addSubview(stack)
        NSLayoutConstraint.activate([
            page.topAnchor.constraint(equalTo: view.topAnchor),
            page.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            page.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            page.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            stack.topAnchor.constraint(equalTo: page.contentLayoutGuide.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: page.contentLayoutGuide.bottomAnchor, constant: -16),
            stack.leadingAnchor.constraint(equalTo: page.frameLayoutGuide.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: page.frameLayoutGuide.trailingAnchor, constant: -16),
        ])

        photo.backgroundColor = .secondarySystemBackground
        photo.contentMode = .scaleAspectFit
        photo.tintColor = product.colour
        photo.heightAnchor.constraint(equalToConstant: 320).isActive = true
        stack.addArrangedSubview(photo)
        stack.addArrangedSubview(text(price(product.price), style: .title2))

        let add = button("Add to cart", #selector(addToCart))
        add.kontalaEvent = .addToCart
        stack.addArrangedSubview(add)
        // A toast or a sound answers no tap: what the page shows is what answers it.
        updateCart()
        stack.addArrangedSubview(inCart)

        let notify = button("Notify me when XL is back", nil)
        notify.isEnabled = false
        stack.addArrangedSubview(notify)
        // Looks like a control, and nothing answers it: a dead tap, a rage tap when pressed again and again.
        stack.addArrangedSubview(button("Compare", nil))
        stack.addArrangedSubview(button("Check delivery date", #selector(checkDelivery)))
        stack.addArrangedSubview(delivery)
        stack.addArrangedSubview(button("Size guide", #selector(sizeGuide)))
        stack.addArrangedSubview(button("Delivery and returns", #selector(deliveryAndReturns)))
        stack.addArrangedSubview(
            text(String(repeating: "Woven from European flax, washed soft. ", count: 40), style: .body))

        // The photo arrives after the page, and the screen is fully shown once it has.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            self?.photo.image = UIImage(systemName: "tshirt.fill")
            Kontala.screenReady()
        }
    }

    private func button(_ title: String, _ action: Selector?) -> UIButton {
        var c = UIButton.Configuration.filled()
        c.title = title
        let b = UIButton(configuration: c)
        if let action = action { b.addTarget(self, action: action, for: .touchUpInside) }
        return b
    }

    private func text(_ s: String, style: UIFont.TextStyle) -> UILabel {
        let l = UILabel()
        l.text = s
        l.font = .preferredFont(forTextStyle: style)
        l.numberOfLines = 0
        return l
    }

    private func updateCart() {
        let n = Shop.shared.count(of: product)
        inCart.text = n == 0 ? "Not in your cart yet" : "\(n) in your cart"
    }

    @objc private func addToCart() {
        Shop.shared.add(product)
        updateCart()
    }

    /// Answers three seconds late, past the second a dead tap waits.
    @objc private func checkDelivery() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            self?.delivery.text = "Arrives on Thursday"
        }
    }

    /// Throws on purpose: an exception nothing catches ends the app, and its next launch sends the `js_error`.
    @objc private func sizeGuide() {
        NSException(name: .internalInconsistencyException, reason: "No size chart for product \(product.id)").raise()
    }

    @objc private func deliveryAndReturns() {
        navigationController?.pushViewController(DeliveryViewController(), animated: true)
    }
}
