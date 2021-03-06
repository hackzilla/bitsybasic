/*
Copyright (c) 2014, 2015 Kristopher Johnson

Permission is hereby granted, free of charge, to any person obtaining
a copy of this software and associated documentation files (the
"Software"), to deal in the Software without restriction, including
without limitation the rights to use, copy, modify, merge, publish,
distribute, sublicense, and/or sell copies of the Software, and to
permit persons to whom the Software is furnished to do so, subject to
the following conditions:

The above copyright notice and this permission notice shall be
included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE
LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION
OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION
WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
*/

import Foundation

// Holds reference to a value
//
// Workaround for Swift's inability to define value types recursively
public class Box<T> {
    public var value: T

    public init(_ value: T) {
        self.value = value
    }
}

/// Given list of strings, produce single string with newlines between those strings
public func lines(strings: String...) -> String {
    return "\n".join(strings)
}

/// Given list of strings, produce single string with newlines between those strings
public func lines(strings: [String]) -> String {
    return "\n".join(strings)
}

/// Return error message associated with current value of `errno`
public func errnoMessage() -> String {
    let err = strerror(errno)
    return String.fromCString(err) ?? "unknown error"
}
