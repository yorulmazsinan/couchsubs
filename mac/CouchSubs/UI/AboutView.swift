// SPDX-License-Identifier: AGPL-3.0-only

import CouchSubsCore
import SwiftUI

struct AboutView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: Theme.space("m")) {
            LogoView(size: 88)
            Text(verbatim: "CouchSubs").font(.csTitle)
            Text(verbatim: AppIdentity.version).foregroundStyle(Color.csSecondary)
            Text(verbatim: "Copyright © 2026 Sinan Yorulmaz")
                .foregroundStyle(Color.csSecondary)
            Text("Free and open source under the GNU AGPL-3.0 license.")
                .multilineTextAlignment(.center)
            Text("Remote Play connection by chiaki-ng (AGPL-3.0). Thanks to its developers.")
                .multilineTextAlignment(.center)
                .foregroundStyle(Color.csSecondary)
            HStack(spacing: Theme.space("m")) {
                Link("Source code", destination: AppIdentity.sourceURL)
                Text(verbatim: "·").foregroundStyle(Color.csSecondary)
                Link(destination: URL(string: "https://github.com/chiaki-ng/chiaki-ng")!) { Text(verbatim: "chiaki-ng") }
            }
            .foregroundStyle(Color.csAccentText)
            Text("CouchSubs is not affiliated with Sony Interactive Entertainment. PlayStation and PS5 are trademarks of Sony Interactive Entertainment Inc.")
                .font(.csCaption).foregroundStyle(Color.csSecondary)
                .multilineTextAlignment(.center)
            Button("Close") { dismiss() }.buttonStyle(.primary).keyboardShortcut(.defaultAction)
        }
        .padding(Theme.space("xxl"))
        .frame(width: 460)
    }
}
