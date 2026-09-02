import Foundation

public enum PartialDatePrecision: String, Codable, CaseIterable, Sendable {
    case year
    case month
    case day
}

public enum PartialDateValidationError: Error, Equatable, Sendable {
    case yearOutOfRange(Int)
    case monthRequired
    case monthNotAllowed
    case monthOutOfRange(Int)
    case dayRequired
    case dayNotAllowed
    case dayOutOfRange(Int)
    case emptyRange
    case rangeIsReversed
}

/// A human date that preserves how much the user actually knows.
///
/// A year-only value is not silently converted to January 1, and a month-only
/// value is not silently converted to the first day of that month.
public struct PartialDate: Codable, Hashable, Sendable, CustomStringConvertible {
    public let year: Int
    public let month: Int?
    public let day: Int?
    public let precision: PartialDatePrecision

    public init(
        year: Int,
        month: Int? = nil,
        day: Int? = nil,
        precision: PartialDatePrecision? = nil
    ) throws {
        let resolvedPrecision = precision ?? (day != nil ? .day : (month != nil ? .month : .year))
        try Self.validate(year: year, month: month, day: day, precision: resolvedPrecision)
        self.year = year
        self.month = month
        self.day = day
        self.precision = resolvedPrecision
    }

    public static func year(_ year: Int) throws -> Self {
        try Self(year: year, precision: .year)
    }

    public static func month(_ month: Int, of year: Int) throws -> Self {
        try Self(year: year, month: month, precision: .month)
    }

    public static func day(_ day: Int, month: Int, year: Int) throws -> Self {
        try Self(year: year, month: month, day: day, precision: .day)
    }

    /// The first possible instant represented by this partial date.
    public var earliestInstant: Date {
        Self.date(
            year: year,
            month: month ?? 1,
            day: day ?? 1,
            hour: 0,
            minute: 0,
            second: 0,
            nanosecond: 0
        )
    }

    /// The last possible instant represented by this partial date.
    public var latestInstant: Date {
        let resolvedMonth = month ?? 12
        let resolvedDay: Int
        switch precision {
        case .year:
            resolvedDay = 31
        case .month:
            resolvedDay = Self.daysInMonth(resolvedMonth, year: year)
        case .day:
            resolvedDay = day ?? 1
        }

        return Self.date(
            year: year,
            month: resolvedMonth,
            day: resolvedDay,
            hour: 23,
            minute: 59,
            second: 59,
            // Date is backed by a floating-point time interval. Keeping one
            // millisecond of headroom avoids rounding the final representable
            // instant into the following day/year during comparisons.
            nanosecond: 999_000_000
        )
    }

    public func contains(_ instant: Date) -> Bool {
        earliestInstant <= instant && instant <= latestInstant
    }

    public var description: String {
        switch precision {
        case .year:
            String(format: "%04d", year)
        case .month:
            String(format: "%04d-%02d", year, month ?? 1)
        case .day:
            String(format: "%04d-%02d-%02d", year, month ?? 1, day ?? 1)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case precision
        case year
        case month
        case day
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let precision = try container.decode(PartialDatePrecision.self, forKey: .precision)
        let year = try container.decode(Int.self, forKey: .year)
        let month = try container.decodeIfPresent(Int.self, forKey: .month)
        let day = try container.decodeIfPresent(Int.self, forKey: .day)
        do {
            try self.init(year: year, month: month, day: day, precision: precision)
        } catch let error as PartialDateValidationError {
            throw DecodingError.dataCorruptedError(
                forKey: .precision,
                in: container,
                debugDescription: "Invalid partial date: \(error)"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(precision, forKey: .precision)
        try container.encode(year, forKey: .year)
        try container.encodeIfPresent(month, forKey: .month)
        try container.encodeIfPresent(day, forKey: .day)
    }

    private static func validate(
        year: Int,
        month: Int?,
        day: Int?,
        precision: PartialDatePrecision
    ) throws {
        guard (1...9_999).contains(year) else {
            throw PartialDateValidationError.yearOutOfRange(year)
        }

        switch precision {
        case .year:
            guard month == nil else { throw PartialDateValidationError.monthNotAllowed }
            guard day == nil else { throw PartialDateValidationError.dayNotAllowed }

        case .month:
            guard let month else { throw PartialDateValidationError.monthRequired }
            guard (1...12).contains(month) else {
                throw PartialDateValidationError.monthOutOfRange(month)
            }
            guard day == nil else { throw PartialDateValidationError.dayNotAllowed }

        case .day:
            guard let month else { throw PartialDateValidationError.monthRequired }
            guard (1...12).contains(month) else {
                throw PartialDateValidationError.monthOutOfRange(month)
            }
            guard let day else { throw PartialDateValidationError.dayRequired }
            let validRange = 1...daysInMonth(month, year: year)
            guard validRange.contains(day) else {
                throw PartialDateValidationError.dayOutOfRange(day)
            }
        }
    }

    private static func date(
        year: Int,
        month: Int,
        day: Int,
        hour: Int,
        minute: Int,
        second: Int,
        nanosecond: Int
    ) -> Date {
        var components = DateComponents()
        components.calendar = calendar
        components.timeZone = utc
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        components.second = second
        components.nanosecond = nanosecond
        // Construction has already been validated, so failure indicates a
        // Foundation calendar invariant rather than recoverable user input.
        return components.date!
    }

    private static func daysInMonth(_ month: Int, year: Int) -> Int {
        let first = date(
            year: year,
            month: month,
            day: 1,
            hour: 0,
            minute: 0,
            second: 0,
            nanosecond: 0
        )
        return calendar.range(of: .day, in: .month, for: first)!.count
    }

    private static var utc: TimeZone {
        TimeZone(secondsFromGMT: 0)!
    }

    private static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        return calendar
    }
}

public struct PartialDateRange: Codable, Hashable, Sendable {
    public let start: PartialDate?
    public let end: PartialDate?

    public init(start: PartialDate? = nil, end: PartialDate? = nil) throws {
        guard start != nil || end != nil else {
            throw PartialDateValidationError.emptyRange
        }
        guard Self.isOrdered(start: start, end: end) else {
            throw PartialDateValidationError.rangeIsReversed
        }
        self.start = start
        self.end = end
    }

    public func contains(_ instant: Date) -> Bool {
        let beginsBefore = start.map { $0.earliestInstant <= instant } ?? true
        let endsAfter = end.map { instant <= $0.latestInstant } ?? true
        return beginsBefore && endsAfter
    }

    public func overlaps(_ other: PartialDateRange) -> Bool {
        let ownStart = start?.earliestInstant ?? .distantPast
        let ownEnd = end?.latestInstant ?? .distantFuture
        let otherStart = other.start?.earliestInstant ?? .distantPast
        let otherEnd = other.end?.latestInstant ?? .distantFuture
        return ownStart <= otherEnd && otherStart <= ownEnd
    }

    public static func isOrdered(start: PartialDate?, end: PartialDate?) -> Bool {
        guard let start, let end else { return true }
        return start.earliestInstant <= end.latestInstant
    }

    private enum CodingKeys: String, CodingKey {
        case start
        case end
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let start = try container.decodeIfPresent(PartialDate.self, forKey: .start)
        let end = try container.decodeIfPresent(PartialDate.self, forKey: .end)
        do {
            try self.init(start: start, end: end)
        } catch let error as PartialDateValidationError {
            throw DecodingError.dataCorruptedError(
                forKey: .start,
                in: container,
                debugDescription: "Invalid partial date range: \(error)"
            )
        }
    }
}

/// Localized user-authored text with a stable fallback for unsupported locales.
public struct LocalizedText: Codable, Hashable, Sendable {
    public var fallback: String
    public var localized: [String: String]

    public init(_ fallback: String, localized: [String: String] = [:]) {
        self.fallback = fallback
        self.localized = localized
    }

    public func resolved(preferredLanguageTags: [String]) -> String {
        for tag in preferredLanguageTags {
            if let exact = localized[tag], !exact.isEmpty {
                return exact
            }
            let language = tag.split(separator: "-").first.map(String.init)
            if let language, let match = localized[language], !match.isEmpty {
                return match
            }
        }
        return fallback
    }
}

public enum CanonicalValidationSeverity: String, Codable, Sendable {
    case warning
    case error
}

public struct CanonicalValidationIssue: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public let code: String
    public let severity: CanonicalValidationSeverity
    public let entityIDs: [UUID]
    public let message: String

    public init(
        code: String,
        severity: CanonicalValidationSeverity = .error,
        entityIDs: [UUID] = [],
        message: String
    ) {
        self.code = code
        self.severity = severity
        self.entityIDs = entityIDs
        self.message = message
        self.id = ([code] + entityIDs.map(\.uuidString)).joined(separator: ":")
    }
}

public struct CanonicalValidationReport: Codable, Hashable, Sendable {
    public let issues: [CanonicalValidationIssue]

    public init(issues: [CanonicalValidationIssue]) {
        self.issues = issues
    }

    public var errors: [CanonicalValidationIssue] {
        issues.filter { $0.severity == .error }
    }

    public var warnings: [CanonicalValidationIssue] {
        issues.filter { $0.severity == .warning }
    }

    public var isValid: Bool { errors.isEmpty }
}
