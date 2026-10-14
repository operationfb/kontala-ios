import Kontala
import UIKit

/// Home: a paged carousel of campaigns, which a swipe moves, and the products, with search, account and the cart in
/// the navigation bar.
final class HomeViewController: UITableViewController, KontalaScreen {
    var kontalaScreenName: String? { "/" }
    var kontalaPageType: KontalaPageType? { .landing }

    private let campaigns = ["Autumn edit", "Free returns", "New linen"]

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Kontala shop"
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "product")
        tableView.rowHeight = 88
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            image: UIImage(systemName: "magnifyingglass"), style: .plain, target: self, action: #selector(search))
        navigationItem.leftBarButtonItem?.accessibilityLabel = "Search"
        navigationItem.leftBarButtonItem?.accessibilityIdentifier = "search"
        let cart = UIBarButtonItem(
            image: UIImage(systemName: "bag"), style: .plain, target: self, action: #selector(cart))
        cart.accessibilityLabel = "Cart"
        cart.accessibilityIdentifier = "cart"
        let account = UIBarButtonItem(
            image: UIImage(systemName: "person.crop.circle"), style: .plain, target: self, action: #selector(account))
        account.accessibilityLabel = "Account"
        account.accessibilityIdentifier = "account"
        navigationItem.rightBarButtonItems = [cart, account]
    }

    /// The carousel is built once the table knows its width, which `viewDidLoad` comes before.
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let width = tableView.bounds.width
        if width > 0 && tableView.tableHeaderView?.bounds.width != width { tableView.tableHeaderView = carousel(width) }
    }

    private func carousel(_ width: CGFloat) -> UIView {
        let pages = UIScrollView(frame: CGRect(x: 0, y: 0, width: width, height: 160))
        pages.isPagingEnabled = true
        pages.showsHorizontalScrollIndicator = false
        pages.contentSize = CGSize(width: width * CGFloat(campaigns.count), height: 160)
        pages.accessibilityIdentifier = "campaigns"
        for (i, name) in campaigns.enumerated() {
            let label = UILabel(frame: CGRect(x: width * CGFloat(i) + 16, y: 12, width: width - 32, height: 136))
            label.text = name
            label.font = .preferredFont(forTextStyle: .title1)
            label.textAlignment = .center
            label.backgroundColor = [UIColor.systemYellow, .systemMint, .systemCyan][i]
            label.layer.cornerRadius = 12
            label.clipsToBounds = true
            pages.addSubview(label)
        }
        return pages
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        Shop.products.count
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let p = Shop.products[indexPath.row]
        let cell = tableView.dequeueReusableCell(withIdentifier: "product", for: indexPath)
        var c = cell.defaultContentConfiguration()
        c.text = p.name
        c.secondaryText = price(p.price)
        c.image = UIImage(systemName: "tshirt.fill")
        c.imageProperties.tintColor = p.colour
        cell.contentConfiguration = c
        cell.accessoryType = .disclosureIndicator
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        navigationController?.pushViewController(
            ProductViewController(product: Shop.products[indexPath.row]), animated: true)
    }

    @objc private func search() { push(SearchView(navigator: Navigator(navigationController)), title: "Search") }

    @objc private func account() { push(AccountView(), title: "Account") }

    @objc private func cart() { navigationController?.pushViewController(CartViewController(), animated: true) }
}
