import XCTest
@testable import Relay

final class ContentClassifierTests: XCTestCase {
    func testClassifiesJSONObject() {
        let json = """
        {"name": "test", "value": 42}
        """
        XCTAssertEqual(ContentClassifier.classify(text: json), .json)
    }

    func testClassifiesJSONArray() {
        let json = """
        [1, 2, 3, "hello"]
        """
        XCTAssertEqual(ContentClassifier.classify(text: json), .json)
    }

    func testClassifiesHTTPURL() {
        XCTAssertEqual(ContentClassifier.classify(text: "https://example.com/path?q=test"), .url)
    }

    func testClassifiesSSHURL() {
        XCTAssertEqual(ContentClassifier.classify(text: "ssh://user@host.com"), .url)
    }

    func testBaredomainNotURL() {
        XCTAssertNotEqual(ContentClassifier.classify(text: "example.com"), .url)
    }

    func testClassifiesTerminalDollarPrompt() {
        let terminal = """
        $ ls -la
        total 32
        drwxr-xr-x  5 user  staff  160 Jan  1 00:00 .
        """
        XCTAssertEqual(ContentClassifier.classify(text: terminal), .terminal)
    }

    func testClassifiesTerminalPercentPrompt() {
        let terminal = """
        % brew install swift
        ==> Downloading...
        """
        XCTAssertEqual(ContentClassifier.classify(text: terminal), .terminal)
    }

    func testClassifiesSwiftCode() {
        let code = """
        func greet(name: String) -> String {
            return "Hello, \\(name)!"
        }
        """
        XCTAssertEqual(ContentClassifier.classify(text: code), .code)
    }

    func testClassifiesPythonCode() {
        let code = """
        def process_data(items):
            for item in items:
                if item.is_valid:
                    yield item.transform()
        """
        XCTAssertEqual(ContentClassifier.classify(text: code), .code)
    }

    func testClassifiesJavaScriptCode() {
        let code = """
        const fetchData = async (url) => {
            const response = await fetch(url);
            return response.json();
        };
        """
        XCTAssertEqual(ContentClassifier.classify(text: code), .code)
    }

    func testClassifiesPlainText() {
        let text = "This is just a regular sentence about something."
        XCTAssertEqual(ContentClassifier.classify(text: text), .text)
    }

    func testClassifiesMultilinePlainText() {
        let text = """
        Hey, can you take a look at this?
        I think there might be a problem with the login flow.
        Users are reporting timeouts.
        """
        XCTAssertEqual(ContentClassifier.classify(text: text), .text)
    }

    func testEmptyStringReturnsText() {
        XCTAssertEqual(ContentClassifier.classify(text: ""), .text)
    }

    func testWhitespaceReturnsText() {
        XCTAssertEqual(ContentClassifier.classify(text: "   \n\t  "), .text)
    }

    func testInvalidJSONWithBracesClassifiedAsCode() {
        let text = """
        {
            func hello() {
                print("world")
            }
        }
        """
        XCTAssertEqual(ContentClassifier.classify(text: text), .code)
    }

    func testMultilineURLNotURL() {
        let text = """
        https://example.com
        https://other.com
        """
        XCTAssertNotEqual(ContentClassifier.classify(text: text), .url)
    }
}
