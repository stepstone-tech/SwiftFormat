//
//  SwiftFormat.swift
//  SwiftFormat
//
//  Created by Nick Lockwood on 12/08/2016.
//  Copyright 2016 Nick Lockwood
//
//  Distributed under the permissive MIT license
//  Get the latest version from here:
//
//  https://github.com/nicklockwood/SwiftFormat
//
//  Permission is hereby granted, free of charge, to any person obtaining a copy
//  of this software and associated documentation files (the "Software"), to deal
//  in the Software without restriction, including without limitation the rights
//  to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
//  copies of the Software, and to permit persons to whom the Software is
//  furnished to do so, subject to the following conditions:
//
//  The above copyright notice and this permission notice shall be included in all
//  copies or substantial portions of the Software.
//
//  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
//  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
//  OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
//  SOFTWARE.
//

import Foundation

/// The current SwiftFormat version
public let version = "0.35.6"

/// The standard SwiftFormat config file name
public let swiftFormatConfigurationFile = ".swiftformat"

/// An enumeration of the types of error that may be thrown by SwiftFormat
public enum FormatError: Error, CustomStringConvertible, LocalizedError, CustomNSError {
    case reading(String)
    case writing(String)
    case parsing(String)
    case options(String)

    public var description: String {
        switch self {
        case let .reading(string),
             let .writing(string),
             let .parsing(string),
             let .options(string):
            return string
        }
    }

    public var localizedDescription: String {
        return "Error: \(description)."
    }

    public var errorUserInfo: [String: Any] {
        return [NSLocalizedDescriptionKey: localizedDescription]
    }
}

/// Legacy file enumeration function
@available(*, deprecated, message: "Use other enumerateFiles() method instead")
public func enumerateFiles(withInputURL inputURL: URL,
                           excluding excludedURLs: [URL] = [],
                           outputURL: URL? = nil,
                           options fileOptions: FileOptions = .default,
                           concurrent: Bool = true,
                           block: @escaping (URL, URL) throws -> () throws -> Void) -> [Error] {
    var fileOptions = fileOptions
    fileOptions.excludedURLs += excludedURLs
    let options = Options(fileOptions: fileOptions)
    return enumerateFiles(
        withInputURL: inputURL,
        outputURL: outputURL,
        options: options,
        concurrent: concurrent
    ) { inputURL, outputURL, _ in
        try block(inputURL, outputURL)
    }
}

/// Callback for enumerateFiles() function
public typealias FileEnumerationHandler = (
    _ inputURL: URL,
    _ ouputURL: URL,
    _ options: Options
) throws -> () throws -> Void

/// Enumerate all swift files at the specified location and (optionally) calculate an output file URL for each.
/// Ignores the file if any of the excluded file URLs is a prefix of the input file URL.
///
/// Files are enumerated concurrently. For convenience, the enumeration block returns a completion block, which
/// will be executed synchronously on the calling thread once enumeration is complete.
///
/// Errors may be thrown by either the enumeration block or the completion block, and are gathered into an
/// array and returned after enumeration is complete, along with any errors generated by the function itself.
/// Throwing an error from inside either block does *not* terminate the enumeration.
public func enumerateFiles(withInputURL inputURL: URL,
                           outputURL: URL? = nil,
                           options baseOptions: Options = .default,
                           concurrent: Bool = true,
                           skipped: FileEnumerationHandler? = nil,
                           handler: @escaping FileEnumerationHandler) -> [Error] {
    guard let resourceValues = try? inputURL.resourceValues(
        forKeys: Set([.isDirectoryKey, .isAliasFileKey, .isSymbolicLinkKey])
    ) else {
        if FileManager.default.fileExists(atPath: inputURL.path) {
            return [FormatError.reading("failed to read attributes for \(inputURL.path)")]
        }
        return [FormatError.options("file not found at \(inputURL.path)")]
    }
    let fileOptions = baseOptions.fileOptions ?? .default
    if !fileOptions.followSymlinks &&
        (resourceValues.isAliasFile == true || resourceValues.isSymbolicLink == true) {
        return [FormatError.options("symbolic link or alias was skipped: \(inputURL.path)")]
    }
    if resourceValues.isDirectory == false &&
        !fileOptions.supportedFileExtensions.contains(inputURL.pathExtension) {
        return [FormatError.options("unsupported file type: \(inputURL.path)")]
    }

    let group = DispatchGroup()
    var completionBlocks = [() throws -> Void]()
    let completionQueue = DispatchQueue(label: "swiftformat.enumeration")
    func onComplete(_ block: @escaping () throws -> Void) {
        completionQueue.async(group: group) {
            completionBlocks.append(block)
        }
    }

    let manager = FileManager.default
    let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .isAliasFileKey, .isSymbolicLinkKey]
    let queue = concurrent ? DispatchQueue.global(qos: .userInitiated) : completionQueue

    func enumerate(inputURL: URL,
                   outputURL: URL?,
                   options: Options) {
        let inputURL = inputURL.standardizedFileURL
        let fileOptions = options.fileOptions ?? .default
        for excludedURL in fileOptions.excludedURLs {
            if inputURL.absoluteString.hasPrefix(excludedURL.standardizedFileURL.absoluteString) {
                if let handler = skipped {
                    do {
                        onComplete(try handler(inputURL, outputURL ?? inputURL, options))
                    } catch {
                        onComplete { throw error }
                    }
                }
                return
            }
        }
        guard let resourceValues = try? inputURL.resourceValues(forKeys: Set(keys)) else {
            onComplete { throw FormatError.reading("failed to read attributes for \(inputURL.path)") }
            return
        }
        if resourceValues.isRegularFile == true {
            if fileOptions.supportedFileExtensions.contains(inputURL.pathExtension) {
                do {
                    onComplete(try handler(inputURL, outputURL ?? inputURL, options))
                } catch {
                    onComplete { throw error }
                }
            }
        } else if resourceValues.isDirectory == true {
            var options = options
            let configFile = inputURL.appendingPathComponent(swiftFormatConfigurationFile)
            if manager.fileExists(atPath: configFile.path) {
                do {
                    let data = try Data(contentsOf: configFile)
                    let args = try parseConfigFile(data)
                    try options.addArguments(args, in: inputURL.path)
                } catch {
                    onComplete { throw error }
                    return
                }
            }
            guard let files = try? manager.contentsOfDirectory(
                at: inputURL, includingPropertiesForKeys: keys, options: .skipsHiddenFiles
            ) else {
                onComplete { throw FormatError.reading("failed to read contents of directory at \(inputURL.path)") }
                return
            }
            for url in files {
                queue.async(group: group) {
                    let outputURL = outputURL.map {
                        URL(fileURLWithPath: $0.path + url.path[inputURL.path.endIndex ..< url.path.endIndex])
                    }
                    enumerate(inputURL: url, outputURL: outputURL, options: options)
                }
            }
        } else if fileOptions.followSymlinks &&
            (resourceValues.isSymbolicLink == true || resourceValues.isAliasFile == true) {
            let resolvedURL = inputURL.resolvingSymlinksInPath()
            enumerate(inputURL: resolvedURL, outputURL: outputURL, options: options)
        }
    }

    queue.async(group: group) {
        if !manager.fileExists(atPath: inputURL.path) {
            onComplete { throw FormatError.options("file not found at \(inputURL.path)") }
            return
        }
        enumerate(inputURL: inputURL, outputURL: outputURL, options: baseOptions)
    }
    group.wait()

    var errors = [Error]()
    for block in completionBlocks {
        do {
            try block()
        } catch {
            errors.append(error)
        }
    }
    return errors
}

/// Get line/column offset for token
/// Note: line indexes start at 1, columns start at zero
public func offsetForToken(at index: Int, in tokens: [Token]) -> (line: Int, column: Int) {
    var line = 1, column = 0
    for token in tokens[0 ..< index] {
        if token.isLinebreak {
            line += 1
            column = 0
        } else {
            column += token.string.count
        }
    }
    return (line, column)
}

/// Process parsing errors
public func parsingError(for tokens: [Token], options: FormatOptions) -> FormatError? {
    if let index = tokens.index(where: {
        guard options.fragment || !$0.isError else { return true }
        guard !options.ignoreConflictMarkers, case let .operator(string, _) = $0 else { return false }
        return string.hasPrefix("<<<<<") || string.hasPrefix("=====") || string.hasPrefix(">>>>>")
    }) {
        let message: String
        switch tokens[index] {
        case .error(""):
            message = "unexpected end of file"
        case let .error(string):
            if string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                message = "inconsistent whitespace in multi-line string literal"
            } else {
                message = "unexpected token \(string)"
            }
        case let .operator(string, _):
            message = "found conflict marker \(string)"
        default:
            preconditionFailure()
        }
        let (line, column) = offsetForToken(at: index, in: tokens)
        return .parsing("\(message) at \(line):\(column)")
    }
    return nil
}

/// Convert a token array back into a string
public func sourceCode(for tokens: [Token]) -> String {
    var output = ""
    for token in tokens { output += token.string }
    return output
}

/// Apply specified rules to a token array with optional callback
/// Useful for perfoming additional logic after each rule is applied
public func applyRules(_ rules: [FormatRule],
                       to originalTokens: [Token],
                       with options: FormatOptions,
                       callback: ((Int, [Token]) -> Void)? = nil) throws -> [Token] {
    var tokens = originalTokens

    // Parse
    if let error = parsingError(for: tokens, options: options) {
        throw error
    }

    // Recursively apply rules until no changes are detected
    var options = options
    for _ in 0 ..< 10 {
        let formatter = Formatter(tokens, options: options)
        for (i, rule) in rules.enumerated() {
            rule(formatter)
            callback?(i, formatter.tokens)
        }
        if tokens == formatter.tokens {
            return tokens
        }
        tokens = formatter.tokens
        options.fileHeader = .ignore // Prevents infinite recursion
    }
    throw FormatError.writing("failed to terminate")
}

/// Format a pre-parsed token array
/// Returns the formatted token array, and the number of edits made
public func format(_ tokens: [Token],
                   rules: [FormatRule] = FormatRules.default,
                   options: FormatOptions = .default) throws -> [Token] {
    return try applyRules(rules, to: tokens, with: options)
}

/// Format code with specified rules and options
public func format(_ source: String,
                   rules: [FormatRule] = FormatRules.default,
                   options: FormatOptions = .default) throws -> String {
    return sourceCode(for: try format(tokenize(source), rules: rules, options: options))
}

// MARK: Path utilities

func expandPath(_ path: String, in directory: String) -> URL {
    if path.hasPrefix("/") {
        return URL(fileURLWithPath: path)
    }
    if path.hasPrefix("~") {
        return URL(fileURLWithPath: NSString(string: path).expandingTildeInPath)
    }
    return URL(fileURLWithPath: directory).appendingPathComponent(path)
}

func pathContainsGlobSyntax(_ path: String) -> Bool {
    return "*?[{".contains(where: { path.contains($0) })
}

// Expand one or more comma-delimited file paths using glob syntax
func expandGlobs(_ paths: String, in directory: String) -> [URL] {
    guard pathContainsGlobSyntax(paths) else {
        return parseCommaDelimitedList(paths).map {
            expandPath($0, in: directory)
        }
    }
    var paths = paths
    var tokens = [String: String]()
    while let range = paths.range(of: "\\{[^}]+\\}", options: .regularExpression) {
        let options = paths[range].dropFirst().dropLast().components(separatedBy: ",")
        let token = "<<<\(tokens.count)>>>"
        tokens[token] = "(\(options.joined(separator: "|")))"
        paths.replaceSubrange(range, with: token)
    }
    return parseCommaDelimitedList(paths).flatMap { path -> [URL] in
        let url = expandPath(path, in: directory)
        if FileManager.default.fileExists(atPath: url.path) {
            // TODO: should we also handle cases where path includes tokens?
            return [url]
        }
        var regex = "^\(url.path)$"
            .replacingOccurrences(of: "[.+(){\\\\|]", with: "\\\\$0", options: .regularExpression)
            .replacingOccurrences(of: "?", with: "[^/]")
            .replacingOccurrences(of: "**/", with: "(.+/)?")
            .replacingOccurrences(of: "**", with: ".+")
            .replacingOccurrences(of: "*", with: "([^/]+)?")
        for (token, replacement) in tokens {
            regex = regex.replacingOccurrences(of: token, with: replacement)
        }
        guard let enumerator = FileManager.default.enumerator(
            at: URL(fileURLWithPath: directory), includingPropertiesForKeys: nil
        ) else {
            return []
        }
        return enumerator.compactMap { url -> URL? in
            let url = url as! URL
            let path = url.path
            guard path.range(of: regex, options: .regularExpression) != nil else {
                return nil
            }
            return url
        }
    }
}

// MARK: Xcode 9.2 compatibility

#if !swift(>=4.1)

    extension Sequence {
        func compactMap<T>(_ transform: (Element) throws -> T?) rethrows -> [T] {
            return try flatMap { try transform($0).map { [$0] } ?? [] }
        }
    }

#endif
