//
//  ImmediateSearchTextField.swift
//  Rewind
//
//  Created by Codex on 6/7/26.
//

import SwiftUI

#if os(iOS)
import UIKit

/// A UIKit-backed search field that can focus as soon as it enters the window.
///
/// SwiftUI focus can lag behind full-screen cover transitions. This local bridge
/// mirrors the immediate responder pattern used by the Albatross chat input
/// without adding a FeatherKit dependency to Rewind.
struct ImmediateSearchTextField: UIViewRepresentable {
    @Binding var text: String
    @Binding var requestFocus: Bool
    @Binding var isFocused: Bool

    let prompt: String
    let isEnabled: Bool
    let onSubmit: () -> Void

    init(
        _ prompt: String,
        text: Binding<String>,
        requestFocus: Binding<Bool>,
        isFocused: Binding<Bool>,
        isEnabled: Bool = true,
        onSubmit: @escaping () -> Void = {}
    ) {
        self.prompt = prompt
        self._text = text
        self._requestFocus = requestFocus
        self._isFocused = isFocused
        self.isEnabled = isEnabled
        self.onSubmit = onSubmit
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIView(context: Context) -> ImmediateSearchTextFieldView {
        let textField = ImmediateSearchTextFieldView()
        textField.delegate = context.coordinator
        textField.addTarget(context.coordinator, action: #selector(Coordinator.textDidChange(_:)), for: .editingChanged)
        textField.onDidMoveToWindow = { [weak coordinator = context.coordinator, weak textField] in
            coordinator?.focusIfNeeded(textField)
        }
        configure(textField)
        return textField
    }

    func updateUIView(_ textField: ImmediateSearchTextFieldView, context: Context) {
        context.coordinator.parent = self

        if textField.text != text {
            textField.text = text
        }

        configure(textField)
        context.coordinator.focusIfNeeded(textField)
    }

    static func dismantleUIView(_ textField: ImmediateSearchTextFieldView, coordinator: Coordinator) {
        if textField.isFirstResponder {
            textField.resignFirstResponder()
        }
    }

    private func configure(_ textField: UITextField) {
        textField.attributedPlaceholder = NSAttributedString(
            string: prompt,
            attributes: [.foregroundColor: UIColor.tertiaryLabel]
        )
        textField.isEnabled = isEnabled
        textField.textColor = .label
        textField.tintColor = .label
        textField.font = .systemFont(
            ofSize: UIFont.preferredFont(forTextStyle: .body).pointSize,
            weight: .semibold
        )
        textField.adjustsFontForContentSizeCategory = true
        textField.backgroundColor = .clear
        textField.borderStyle = .none
        textField.clearButtonMode = .never
        textField.keyboardAppearance = .dark
        textField.returnKeyType = .search
        textField.autocorrectionType = .default
        textField.autocapitalizationType = .sentences
    }

    @MainActor
    final class Coordinator: NSObject, UITextFieldDelegate {
        var parent: ImmediateSearchTextField

        init(_ parent: ImmediateSearchTextField) {
            self.parent = parent
        }

        func focusIfNeeded(_ textField: UITextField?) {
            guard let textField else {
                return
            }

            let wantsFocus = parent.requestFocus || parent.isFocused
            if wantsFocus, textField.window != nil, !textField.isFirstResponder {
                textField.becomeFirstResponder()
            } else if !wantsFocus, textField.isFirstResponder {
                textField.resignFirstResponder()
            }
        }

        @objc func textDidChange(_ textField: UITextField) {
            parent.text = textField.text ?? ""
        }

        func textFieldDidBeginEditing(_ textField: UITextField) {
            Task { @MainActor [weak self] in
                guard let self else {
                    return
                }

                parent.isFocused = true
                parent.requestFocus = false
            }
        }

        func textFieldDidEndEditing(_ textField: UITextField) {
            Task { @MainActor [weak self] in
                self?.parent.isFocused = false
            }
        }

        func textFieldShouldReturn(_ textField: UITextField) -> Bool {
            parent.onSubmit()
            return true
        }
    }
}

final class ImmediateSearchTextFieldView: UITextField {
    var onDidMoveToWindow: (() -> Void)?

    override func didMoveToWindow() {
        super.didMoveToWindow()

        if window != nil {
            onDidMoveToWindow?()
        }
    }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: 24)
    }
}
#endif
