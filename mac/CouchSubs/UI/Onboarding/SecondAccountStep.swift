// SPDX-License-Identifier: AGPL-3.0-only

import SwiftUI

struct SecondAccountStep: View {
    var body: some View {
        StepLayout(title: "A second PSN account",
                   message: "CouchSubs watches the game through Remote Play. If it used your own account, the PS5 would turn off your controller. With a second account you keep playing undisturbed.") {
            VStack(alignment: .leading, spacing: Theme.space("l")) {
                NumberedRow(number: 1, text: "Create a free account at playstation.com with a different email address.")
                NumberedRow(number: 2, text: "On the PS5, choose Add User and sign in once with the new account.")
                NumberedRow(number: 3, text: "Still as the new user, go to Settings › System › Remote Play and turn on Enable Remote Play.")
                NumberedRow(number: 4, text: "Switch back to your own user. You only do this once.")
            }
        }
    }
}
