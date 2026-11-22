// SPDX-License-Identifier: AGPL-3.0-only

import SwiftUI

// Kurulum sihirbazı artık yeni arayüzde: UI/Yeni/WizardView.swift. Burada eski adım görünümlerinin ortak ortamı kalır.

extension EnvironmentValues {
    /// Sihirbazın kaydırma alanında verilen kimlikli görünüme kaydırır (adımın dışında hiçbir şey yapmaz).
    @Entry var scrollOnboardingTo: (String) -> Void = { _ in }
}
