import WidgetKit
import SwiftUI

@main
struct HeartRateWidgetBundle: WidgetBundle {
    var body: some Widget {
        HeartRateWidget()
        HeartRateCurveWidget()
    }
}
