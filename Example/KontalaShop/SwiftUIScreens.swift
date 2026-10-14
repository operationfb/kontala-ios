import Kontala
import SwiftUI

/// Checkout: address fields told apart by their content types, a card number the app masks, and a declared purchase,
/// which opens the order's confirmation.
struct CheckoutView: View {
    @EnvironmentObject var shop: Shop
    let navigator: Navigator
    @State private var name = ""
    @State private var street = ""
    @State private var postcode = ""
    @State private var card = ""
    @State private var paid: Double?

    var body: some View {
        if let total = paid {
            VStack(spacing: 16) {
                Text("Thank you").font(.largeTitle)
                Text("Your order of \(price(total)) is on its way.")
                Button("Keep shopping") { navigator.back() }.kontalaEvent(id: "keep_shopping")
            }
            .kontalaScreen("/order/confirmed", pageType: .orderConfirmation, properties: ["value": total])
        } else {
            Form {
                Section("Delivery") {
                    TextField("Full name", text: $name).textContentType(.name)
                    TextField("Street", text: $street).textContentType(.streetAddressLine1)
                    TextField("Postcode", text: $postcode).textContentType(.postalCode)
                }
                Section("Payment") {
                    // Masked: a tap here names nothing but that it was a field.
                    TextField("Card number", text: $card).keyboardType(.numberPad).kontalaMask()
                }
                Section {
                    Button("Pay \(price(shop.total))") {
                        paid = shop.total
                        shop.empty()
                    }
                    .kontalaEvent(.purchase, id: "pay")
                    .disabled(shop.lines.isEmpty)
                }
            }
            .kontalaScreen("/checkout", pageType: .checkout)
        }
    }
}

/// Account: a declared login whose email names who signs in, the tracking prompt, and the app's own analytics consent,
/// which the pages it shows take as theirs.
struct AccountView: View {
    @State private var email = ""
    @State private var password = ""
    @State private var signedIn: String?
    @State private var tracking = "Not asked"
    @State private var analytics = Kontala.consentState == .granted

    var body: some View {
        Form {
            if let who = signedIn {
                Section("Signed in") {
                    Text(who)
                    Button("Sign out") {
                        signedIn = nil
                        Kontala.identify()
                    }
                    .kontalaEvent(id: "sign_out")
                }
            } else {
                Section("Sign in") {
                    TextField("Email", text: $email)
                        .textContentType(.username).keyboardType(.emailAddress).textInputAutocapitalization(.never)
                    SecureField("Password", text: $password).textContentType(.password).submitLabel(.done)
                    Button("Sign in") {
                        signedIn = email
                        Kontala.identify(user: email)
                    }
                    .kontalaEvent(.login, id: "sign_in")
                    .disabled(email.isEmpty || password.isEmpty)
                }
            }
            Section("Privacy") {
                Toggle("Share analytics", isOn: $analytics)
                    .onChange(of: analytics) { on in Kontala.consent(on ? .granted : .denied) }
                Button("Ask to track") {
                    Kontala.requestTrackingAuthorization { answer in
                        DispatchQueue.main.async { tracking = answer ?? "Not available" }
                    }
                }
                .kontalaEvent(id: "ask_to_track")
                LabeledContent("Tracking", value: tracking)
            }
        }
        .kontalaScreen("/account", pageType: .form)
    }
}

/// Search: the keyboard's Search sends the box's term, and a result opens its product.
struct SearchView: View {
    let navigator: Navigator
    @State private var term = ""
    @State private var searched = ""

    private var results: [Product] {
        searched.isEmpty ? [] : Shop.products.filter { $0.name.localizedCaseInsensitiveContains(searched) }
    }

    var body: some View {
        List {
            TextField("Search the shop", text: $term)
                .submitLabel(.search)
                .textInputAutocapitalization(.never)
                .onSubmit { searched = term }
            if !searched.isEmpty && results.isEmpty { Text("Nothing matches “\(searched)”") }
            ForEach(results) { p in
                Button(p.name) { navigator.open(p) }.kontalaEvent(.selectItem, id: "result_\(p.id)")
            }
        }
        .kontalaScreen("/search", pageType: .search)
    }
}
