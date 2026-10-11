// Kontala's closed vocabularies, as the collector holds them
// (collector/pagesignals/vocab.go, collector/clicks/vocab.go). The tests hold
// both enums to the collector's own vectors, so a type added there fails this
// SDK's suite until it is added here.

/// Whether the visitor allows analytics, with the web tag's three states.
public enum KontalaConsent: String, CaseIterable {
    /// The default, the tag's permissive one: the app states the basis.
    case granted

    /// Events are sent without anything that identifies the visitor, which the collector redacts; nothing is stored
    /// on the device.
    case denied

    /// Events wait in memory for an answer, up to the hold, and are then sent as unknown, which the collector also
    /// redacts.
    case unknown

    /// The state as the API names it.
    public var wire: String { rawValue }
}

/// A page type a screen may declare, as `Kontala.pageType` or a declared screen does. A declared type always wins
/// over anything Kontala works out.
public enum KontalaPageType: String, CaseIterable {
    case landing = "landing"
    case productList = "plp"
    case search = "search"
    case productDetail = "pdp"
    case cart = "cart"
    case checkout = "checkout"
    case orderConfirmation = "order_confirmation"
    case pricing = "pricing"
    case form = "form"
    case formConfirmation = "form_confirmation"
    case other = "other"

    /// The type as the API names it.
    public var wire: String { rawValue }
}

/// A click type a control may declare, as `data-ac-event` declares one on the web.
public enum KontalaClickType: String, CaseIterable {
    case viewItemList = "view_item_list"
    case filterSort = "filter_sort"
    case selectItem = "select_item"
    case compare = "compare"
    case variantSelect = "variant_select"
    case addToCart = "add_to_cart"
    case removeFromCart = "remove_from_cart"
    case beginCheckout = "begin_checkout"
    case promoCode = "promo_code"
    case checkoutContactInfoSubmitted = "checkout_contact_info_submitted"
    case checkoutAddressInfoSubmitted = "checkout_address_info_submitted"
    case checkoutShippingInfoSubmitted = "checkout_shipping_info_submitted"
    case addPaymentInfo = "add_payment_info"
    case purchase = "purchase"
    case search = "search"
    case selectOffer = "select_offer"
    case startTrial = "start_trial"
    case requestDemo = "request_demo"
    case beginApplication = "begin_application"
    case submitApplication = "submit_application"
    case trackOrder = "track_order"
    case cancelOrder = "cancel_order"
    case returnOrder = "return_order"
    case download = "download"
    case login = "login"
    case signUp = "sign_up"
    case newsletterSignup = "newsletter_signup"
    case chat = "chat"
    case contact = "contact"
    case support = "support"

    /// The type as the API names it.
    public var wire: String { rawValue }
}
