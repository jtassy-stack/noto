import Testing
import Foundation
@testable import Noto

@Suite("MonLycée class reader")
struct MonLyceeClassReaderTests {

    @Test("Direct class keys")
    func direct() {
        #expect(MonLyceeClassReader.className(in: ["className": "2NDE2"]) == "2NDE2")
        #expect(MonLyceeClassReader.className(in: ["classe": "6EME2"]) == "6EME2")
        #expect(MonLyceeClassReader.className(in: ["division": " 1G3 "]) == "1G3")
    }

    @Test("Nested class objects and arrays")
    func nested() {
        let individual: [String: Any] = [
            "firstName": "Gaston",
            "classes": [["id": "c1", "name": "2NDE2"]],
        ]
        #expect(MonLyceeClassReader.className(in: individual) == "2NDE2")
    }

    @Test("Homework and grade text never becomes a class")
    func skipsSchoolData() {
        let individual: [String: Any] = [
            "firstName": "Joseph",
            "work": ["notebook": [["subject": "Maths", "className": "3e trimestre"]]],
            "notation": ["grades": [["class": "4e"]]],
        ]
        #expect(MonLyceeClassReader.className(in: individual) == nil)
    }

    @Test("Unrelated keys and unrecognised labels are ignored")
    func ignoresNoise() {
        #expect(MonLyceeClassReader.className(in: ["lastName": "6EME"]) == nil)
        #expect(MonLyceeClassReader.className(in: ["className": "Groupe latin"]) == nil)
    }
}
