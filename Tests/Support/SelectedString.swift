import AppKit

extension NSTextView {
    /// The selected text, for checks that compare what a find selected.
    var selectedString: String { (string as NSString).substring(with: selectedRange()) }
}
