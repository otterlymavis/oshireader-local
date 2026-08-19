import Foundation

/// Shared container the main app, the widget extension, and the share
/// extension all read/write into — none of them can reach another target's
/// private Documents directory.
let oshiReaderAppGroupID = "group.com.otterpia.oshireader"
