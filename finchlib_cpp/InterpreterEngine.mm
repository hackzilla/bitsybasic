/*
Copyright (c) 2015 Kristopher Johnson

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

#include "InterpreterEngine.h"
#include "parse.h"
#include "pasteboard.h"

#include <unistd.h>
#include <dirent.h>

// Keys used for property list
static NSString *StateKey = @"state";
static NSString *VariablesKey = @"variables";
static NSString *ArrayCountKey = @"arrayCount";
static NSString *ArrayValuesKey = @"arrayValues";
static NSString *InputLineBufferKey = @"inputLineBuffer";
static NSString *ProgramKey = @"program";
static NSString *ProgramIndexKey = @"programIndex";
static NSString *ReturnStackKey = @"returnStack";
static NSString *IsTraceOnKey = @"isTraceOn";
static NSString *HasReachedEndOfInputKey = @"hasReachedEndOfInput";
static NSString *InputLvaluesKey = @"inputLvalues";
static NSString *StateBeforeInputKey = @"stateBeforeInput";


namespace finchlib_cpp
{

/// Values for `kind` field of `InterpreterEngine::Line`
enum class LineKind : NSInteger
{
    NumberedStatement,
    UnnumberedStatement,
    Empty,
    EmptyNumberedLine,
    Error
};


/// An input line is parsed to be a statement preceded by a line number,
/// which will be inserted into the program, or a statement without a preceding
/// line number, which will be executed immediately.
///
/// Also possible are empty input lines, which are ignored, or unparseable
/// input lines, which generate an error message.
struct Line
{
    LineKind kind;
    Number lineNumber;
    Statement statement;
    string errorMessage;

    static Line numberedStatement(Number n, Statement s)
    {
        return {LineKind::NumberedStatement, n, s};
    }

    static Line unnumberedStatement(Statement s)
    {
        return {LineKind::UnnumberedStatement, 0, s};
    }

    static Line empty()
    {
        return {LineKind::Empty, 0, Statement::invalid()};
    }

    static Line emptyNumberedLine(Number n)
    {
        return {LineKind::EmptyNumberedLine, n, Statement::invalid()};
    }

    static Line error(string message)
    {
        return {LineKind::Error, 0, Statement::invalid(), message};
    }
};

#pragma mark - InterpreterEngine

InterpreterEngine::InterpreterEngine(Interpreter *interp)
    : interpreter{interp}, a(1024)
{
    clearVariablesAndArray();
}

NSDictionary *InterpreterEngine::stateAsPropertyList()
{
    auto dict = [NSMutableDictionary dictionary];

    // state
    dict[StateKey] = @(st);

    // v
    //
    // We encode only the non-zero values
    auto vValues = [NSMutableDictionary dictionary];
    for (const auto &i : v)
    {
        auto value = i.second;
        if (value != 0)
        {
            auto varname = i.first;
            vValues[@(varname)] = @(value);
        }
    }
    dict[VariablesKey] = vValues;

    // a
    //
    // To encode the (probably sparse) array, we note the size and then
    // save only the non-zero values
    dict[ArrayCountKey] = @(a.size());
    auto aValues = [NSMutableDictionary dictionary];
    for (auto i = 0; i < a.size(); ++i)
    {
        auto value = a[i];
        if (value != 0)
        {
            aValues[@(i)] = @(value);
        }
    }
    dict[ArrayValuesKey] = aValues;

    // inputLineBuffer
    auto inputLineData = [NSData dataWithBytes:inputLineBuffer.data()
                                        length:inputLineBuffer.size()];
    dict[InputLineBufferKey] = inputLineData;

    // program
    auto programText = [NSString stringWithUTF8String:programAsString().c_str()];
    dict[ProgramKey] = programText;

    // programIndex
    dict[ProgramIndexKey] = @(programIndex);

    // inputLvalues
    auto lvalues = [NSMutableArray array];
    for (const auto &lv : inputLvalues)
    {
        NSString *value = [NSString stringWithUTF8String:lv.listText().c_str()];
        [lvalues addObject:value];
    }
    dict[InputLvaluesKey] = lvalues;

    // isTraceOn
    dict[IsTraceOnKey] = @(isTraceOn);

    // hasReachedEndOfInput
    dict[HasReachedEndOfInputKey] = @(hasReachedEndOfInput);

    // stateBeforeInput
    dict[StateBeforeInputKey] = @(stateBeforeInput);

    return dict;
}

void InterpreterEngine::restoreStateFromPropertyList(NSDictionary *dict)
{
    // Note: The "simple" elements like `state`, `hasReachedEndOfInput`, etc. are restored
    // after restoring the more complex elements, which may themselves make changes
    // to those simple members as part of their restoration process.

    // v
    NSDictionary *vValues = dict[VariablesKey];
    if ([vValues isKindOfClass:[NSDictionary class]])
    {
        [vValues enumerateKeysAndObjectsUsingBlock:^(id key, id value, BOOL *stop) {
            if ([key isKindOfClass:[NSNumber class]] && [value isKindOfClass:[NSNumber class]]) {
                v[[key unsignedCharValue]] = [value intValue];
            }
            else {
                assert(false);
            }
        }];
    }
    else
    {
        assert(false);
    }

    // a
    NSNumber *arraySize = dict[ArrayCountKey];
    if ([arraySize isKindOfClass:[NSNumber class]])
    {
        a.resize(arraySize.unsignedIntegerValue);
        fill(begin(a), end(a), 0);

        NSDictionary *aValues = dict[ArrayValuesKey];
        if ([aValues isKindOfClass:[NSDictionary class]])
        {
            [aValues enumerateKeysAndObjectsUsingBlock:^(id key, id value, BOOL *stop) {
                if ([key isKindOfClass:[NSNumber class]] && [value isKindOfClass:[NSNumber class]]) {
                    a[[key unsignedIntegerValue]] = [value intValue];
                }
                else {
                    assert(false);
                }
            }];
        }
    }
    else
    {
        assert(false);
    }

    // inputLineBuffer
    NSData *inputLineData = dict[InputLineBufferKey];
    if ([inputLineData isKindOfClass:[NSData class]])
    {
        const auto length = inputLineData.length;
        inputLineBuffer.resize(length);
        [inputLineData getBytes:inputLineBuffer.data() length:length];
    }
    else
    {
        assert(false);
    }

    // program
    NSString *programText = dict[ProgramKey];
    if ([programText isKindOfClass:[NSString class]])
    {
        interpretString(programText.UTF8String);
    }
    else
    {
        assert(false);
    }

    // programIndex
    NSNumber *pi = dict[ProgramIndexKey];
    if ([pi isKindOfClass:[NSNumber class]])
    {
        programIndex = pi.integerValue;
    }
    else
    {
        assert(false);
    }

    // inputLvalues
    NSArray *lvalues = dict[InputLvaluesKey];
    if ([lvalues isKindOfClass:[NSArray class]])
    {
        for (NSString *lvText in lvalues)
        {
            if ([lvText isKindOfClass:[NSString class]])
            {
                const auto lv = lvalueFromString(lvText.UTF8String);
                if (lv.wasParsed())
                {
                    inputLvalues.push_back(lv.value());
                }
                else
                {
                    assert(false);
                }
            }
            else
            {
                assert(false);
            }
        }
    }
    else
    {
        assert(false);
    }

    // isTraceOn
    NSNumber *ito = dict[IsTraceOnKey];
    if ([ito isKindOfClass:[NSNumber class]])
    {
        isTraceOn = ito.boolValue;
    }
    else
    {
        assert(false);
    }

    // hasReachedEndOfInput
    NSNumber *hreof = dict[HasReachedEndOfInputKey];
    if ([hreof isKindOfClass:[NSNumber class]])
    {
        hasReachedEndOfInput = hreof.boolValue;
    }
    else
    {
        assert(false);
    }

    // stateBeforeInput
    NSNumber *sbi = dict[StateBeforeInputKey];
    if ([sbi isKindOfClass:[NSNumber class]])
    {
        stateBeforeInput = static_cast<InterpreterState>(sbi.intValue);
    }
    else
    {
        assert(false);
    }

    // state
    NSNumber *state = dict[StateKey];
    if ([state isKindOfClass:[NSNumber class]])
    {
        st = static_cast<InterpreterState>(state.integerValue);
    }
    else
    {
        assert(false);
    }
}

string InterpreterEngine::programAsString()
{
    auto s = ostringstream{};
    for (const auto &line : program)
    {
        s << line.lineNumber << " " << line.statement.listText() << "\n";
    }

    return s.str();
}

void InterpreterEngine::interpretString(const string &s)
{
    auto index = size_t{0};

    // Read lines until end-of-stream or error
    auto keepGoing = bool{true};
    do
    {
        const auto inputLineResult = getInputLine([&]() -> InputCharResult
                                                  {
                                                          if (index >= s.length()) {
                                                              return InputCharResult_EndOfStream();
                                                          }
                                                          else {
                                                              return InputCharResult_Value(s[index++]);
                                                          }
        });

        switch (inputLineResult.kind)
        {
            case InputResultKindValue:
                processInput(inputLineResult.value);
                break;

            case InputResultKindEndOfStream:
                keepGoing = false;
                break;

            default:
                // getInputLine() for file should only return Value or EndOfStream
                assert(false);
                keepGoing = false;
                break;
        }
    } while (keepGoing);
}


/// Return interpreter state
InterpreterState InterpreterEngine::state()
{
    return st;
}

/// Halt execution
void InterpreterEngine::breakExecution()
{
    if ((st == InterpreterStateRunning || st == InterpreterStateReadingInput)
        && (programIndex < program.size()))
    {
        const auto &currentLine = program[programIndex];
        const auto lineNumber = currentLine.lineNumber;
        auto msg = ostringstream{};
        msg << "BREAK at line " << lineNumber;
        showError(msg.str());
    }
    else
    {
        showError("BREAK");
    }

    st = InterpreterStateIdle;
}

/// Set values of all variables and array elements to zero
void InterpreterEngine::clearVariablesAndArray()
{
    for (auto varname = 'A'; varname <= 'Z'; ++varname)
    {
        v[varname] = 0;
    }

    fill(begin(a), end(a), 0);
}

/// Remove program from memory
void InterpreterEngine::clearProgram()
{
    program.resize(0);
    programIndex = 0;
    st = InterpreterStateIdle;
}

/// Remove all items from the return stack
void InterpreterEngine::clearReturnStack()
{
    returnStack.resize(0);
}


#pragma mark - Top-level loop

/// Display prompt and read input lines and interpret them until end of input.
///
/// This method should only be used when `InterpreterIO.getInputChar()`
/// will never return `InputCharResult.Waiting`.
/// Otherwise, host should call `next()` in a loop.
void InterpreterEngine::runUntilEndOfInput()
{
    hasReachedEndOfInput = false;
    do
    {
        next();
    } while (!hasReachedEndOfInput);
}

/// Perform next operation.
///
/// The host can drive the interpreter by calling `next()`
/// in a loop.
void InterpreterEngine::next()
{
    switch (st)
    {
        case InterpreterStateIdle:
            [interpreter.io showCommandPromptForInterpreter:interpreter];
            st = InterpreterStateReadingStatement;
            break;

        case InterpreterStateReadingStatement:
        {
            const auto result = readInputLine();
            switch (result.kind)
            {
                case InputResultKindValue:
                    processInput(result.value);
                    break;

                case InputResultKindEndOfStream:
                    hasReachedEndOfInput = true;
                    break;

                case InputResultKindWaiting:
                    // do nothing
                    break;

                default:
                    // should be no other cases
                    assert(false);
            }
        }
        break;

        case InterpreterStateRunning:
            executeNextProgramStatement();
            break;

        case InterpreterStateReadingInput:
            continueInput();
            break;

        default:
            // Should be no other cases
            assert(false);
    }
}

/// Parse an input line and execute it or add it to the program
void InterpreterEngine::processInput(const InputLine &input)
{
    st = InterpreterStateIdle;

    const auto line = parseInputLine(input);

    switch (line.kind)
    {
        case LineKind::UnnumberedStatement:
            execute(line.statement);
            break;

        case LineKind::NumberedStatement:
            insertLineIntoProgram(line.lineNumber, line.statement);
            break;

        case LineKind::EmptyNumberedLine:
            deleteLineFromProgram(line.lineNumber);
            break;

        case LineKind::Empty:
            // Do nothing
            break;

        case LineKind::Error:
            showError(line.errorMessage);
            break;

        default:
            // Should be no other cases
            assert(false);
    }
}

#pragma mark - Parsing

Line InterpreterEngine::parseInputLine(const InputLine &input)
{
    const auto start = InputPos{input, 0};
    const auto afterSpaces = start.afterSpaces();

    // If there are no non-space characters, skip this line
    if (afterSpaces.isAtEndOfLine())
    {
        return Line::empty();
    }

    // If line starts with a number, add the statement to the program
    const auto parsedNumber = numberLiteral(afterSpaces);
    if (parsedNumber.wasParsed())
    {
        if (parsedNumber.nextPos().isRemainingLineEmpty())
        {
            return Line::emptyNumberedLine(parsedNumber.value());
        }

        const auto parsedStatement = statement(parsedNumber.nextPos());
        if (parsedStatement.wasParsed())
        {
            if (parsedStatement.nextPos().isRemainingLineEmpty())
            {
                return Line::numberedStatement(parsedNumber.value(),
                                               parsedStatement.value());
            }
            else
            {
                ostringstream msg;
                msg << "line " << parsedNumber.value()
                    << ": error: not a valid statement";
                return Line::error(msg.str());
            }
        }
        else
        {
            ostringstream msg;
            msg << "line " << parsedNumber.value()
                << ": error: not a valid statement";
            return Line::error(msg.str());
        }
    }

    // Otherwise, try to execute statement immediately
    const auto parsedStatement = statement(afterSpaces);
    if (parsedStatement.wasParsed())
    {
        if (parsedStatement.nextPos().isRemainingLineEmpty())
        {
            return Line::unnumberedStatement(parsedStatement.value());
        }
        else
        {
            return Line::error("error: not a valid statement");
        }
    }
    else
    {
        return Line::error("error: not a valid statement");
    }
}

#pragma mark - Program editing

void InterpreterEngine::insertLineIntoProgram(Number lineNumber,
                                              Statement statement)
{
    NumberedStatement line{lineNumber, statement};

    const auto existing = programLineWithNumber(lineNumber);
    if (existing != program.end())
    {
        *existing = line;
    }
    else if (lineNumber > getLastProgramLineNumber())
    {
        program.push_back(line);
    }
    else
    {
        // TODO: Rather than appending element and re-sorting, it would
        // probably be more efficient to find the correct insertion location
        // and do an insert operation.

        program.push_back(line);
        sort(program.begin(), program.end(),
             [](const NumberedStatement &lhs, const NumberedStatement &rhs)
                 -> bool
             { return lhs.lineNumber < rhs.lineNumber; });
    }
}

/// Delete the line with the specified number from the program.
///
/// No effect if there is no such line.
void InterpreterEngine::deleteLineFromProgram(Number lineNumber)
{
    const auto it = programLineWithNumber(lineNumber);
    if (it != program.end())
    {
        program.erase(it);
    }
}

/// Find program line with specified line number.
///
/// Returns iterator to the element if found, or `program.cend()` if not found.
Program::iterator InterpreterEngine::programLineWithNumber(Number lineNumber)
{
    return find_if(program.begin(), program.end(),
                   [lineNumber](const NumberedStatement &s)
                       -> bool
                   { return s.lineNumber == lineNumber; });
}

/// Return line number of the last line in the program.
///
/// Returns 0 if there is no program.
Number InterpreterEngine::getLastProgramLineNumber()
{
    if (program.size() > 0)
    {
        return program.back().lineNumber;
    }

    return 0;
}

#pragma mark - Execution

void InterpreterEngine::execute(Statement statement)
{
    statement.execute(*this);
}

void InterpreterEngine::executeNextProgramStatement()
{
    assert(st == InterpreterStateRunning);

    if (programIndex >= program.size())
    {
        showError("error: RUN - program does not terminate with END");
        st = InterpreterStateIdle;
        return;
    }

    const auto numberedStatement = program.at(programIndex);
    if (isTraceOn)
    {
        auto msg = ostringstream{};
        msg << "[" << numberedStatement.lineNumber << "]";
        NSString *message = [NSString stringWithUTF8String:msg.str().c_str()];
        [interpreter.io showDebugTraceMessage:message forInterpreter:interpreter];
    }
    ++programIndex;
    execute(numberedStatement.statement);
}

/// Display error message and stop running
///
/// Call this method if an unrecoverable error happens while executing a
/// statement
void InterpreterEngine::abortRunWithErrorMessage(string message)
{
    showError(message);
    if (st == InterpreterStateRunning || st == InterpreterStateReadingInput)
    {
        showError("abort: program terminated");
    }
    st = InterpreterStateIdle;
}

#pragma mark - I/O

/// Send a single character to the output stream
void InterpreterEngine::writeOutput(Char c)
{
    [interpreter.io putOutputChar:c forInterpreter:interpreter];
}

/// Send characters to the output stream
void InterpreterEngine::writeOutput(const vec<Char> &chars)
{
    for (const auto c : chars)
    {
        [interpreter.io putOutputChar:c forInterpreter:interpreter];
    }
}

/// Send string to the output stream
void InterpreterEngine::writeOutput(const string &s)
{
    for (const auto c : s)
    {
        [interpreter.io putOutputChar:c forInterpreter:interpreter];
    }
}

/// Print an object that conforms to the PrintTextProvider protocol
void InterpreterEngine::writeOutput(const PrintTextProvider &p)
{
    writeOutput(p.printText(v, a));
}

/// Display error message
void InterpreterEngine::showError(const string &message)
{
    auto str = [NSString stringWithUTF8String:message.c_str()];
    [interpreter.io showErrorMessage:str forInterpreter:interpreter];
}

/// Read a line using the InterpreterIO interface.
///
/// Return array of characters, or nil if at end of input stream.
///
/// Result does not include any non-graphic characters that were in the input
/// stream.
/// Any horizontal tab ('\t') in the input will be converted to a single space.
///
/// Result may be an empty array, indicating an empty input line, not end of
/// input.
InputLineResult InterpreterEngine::readInputLine()
{
    const auto io = interpreter.io;
    const auto interpreter = this->interpreter;
    return getInputLine([=]() -> InputCharResult
                        { return [io getInputCharForInterpreter:interpreter]; });
}

/// Get a line of input, using specified function to retrieve characters.
///
/// Result does not include any non-graphic characters that were in the input
/// stream.
/// Any horizontal tab ('\t') in the input will be converted to a single space.
InputLineResult
InterpreterEngine::getInputLine(function<InputCharResult()> getChar)
{
    for (;;)
    {
        const auto inputCharResult = getChar();
        switch (inputCharResult.kind)
        {
            case InputResultKindValue:
            {
                const auto c = inputCharResult.value;
                if (c == '\n')
                {
                    const auto result = InputLineResult::inputLine(inputLineBuffer);
                    inputLineBuffer.clear();
                    return result;
                }
                else if (c == '\t')
                {
                    // Convert tabs to spaces
                    inputLineBuffer.push_back(' ');
                }
                else if (' ' <= c && c <= '~')
                {
                    inputLineBuffer.push_back(c);
                }
            }
            break;

            case InputResultKindEndOfStream:
                if (inputLineBuffer.size() > 0)
                {
                    const auto result = InputLineResult::inputLine(inputLineBuffer);
                    inputLineBuffer.clear();
                    return result;
                }
                return InputLineResult::endOfStream();

            case InputResultKindWaiting:
                return InputLineResult::waiting();
        }
    }
}

#pragma mark - Variables and array elements

Number InterpreterEngine::evaluate(const Expression &expr)
{
    return expr.evaluate(v, a);
}

Number InterpreterEngine::getVariableValue(VariableName variableName) const
{
    auto it = v.find(variableName);
    return (it == v.end()) ? 0 : it->second;
}

void InterpreterEngine::setVariableValue(VariableName variableName,
                                         Number value)
{
    assert('A' <= variableName && variableName <= 'Z');
    v[variableName] = value;
}

Number InterpreterEngine::getArrayElementValue(Number index)
{
    if (index >= 0)
    {
        return a[index % a.size()];
    }
    else
    {
        auto fromEnd = -index % a.size();
        return a[a.size() - fromEnd];
    }
}

void InterpreterEngine::setArrayElementValue(Number index, Number value)
{
    if (index >= 0)
    {
        a[index % a.size()] = value;
    }
    else
    {
        auto fromEnd = -index % a.size();
        a[a.size() - fromEnd] = value;
    }
}

void InterpreterEngine::setArrayElementValue(const Expression &indexExpression,
                                             Number value)
{
    const auto index = evaluate(indexExpression);
    setArrayElementValue(index, value);
}

#pragma mark - Statements

/// Execute PRINT statement with arguments
void InterpreterEngine::PRINT(const PrintList &printList)
{
    const auto output = printList.printText(v, a);
    writeOutput(output);
}

/// Execute PRINT statement with no arguments
void InterpreterEngine::PRINT() { writeOutput('\n'); }

/// Execute LIST statement
void InterpreterEngine::LIST(const Expression &lowExpr,
                             const Expression &highExpr)
{
    const auto rangeLow = evaluate(lowExpr);
    const auto rangeHigh = evaluate(highExpr);
    for (const auto &line : program)
    {
        if (line.lineNumber < rangeLow)
            continue;

        if (line.lineNumber > rangeHigh)
            break;

        ostringstream s;
        s << line.lineNumber << " " << line.statement.listText() << "\n";
        writeOutput(s.str());
    }
}

/// Execute IF statement
void InterpreterEngine::IF(const Expression &lhs,
                           const RelOp &op,
                           const Expression &rhs,
                           const Statement &consequent)
{
    const auto lhsValue = evaluate(lhs);
    const auto rhsValue = evaluate(rhs);
    if (op.isTrueForNumbers(lhsValue, rhsValue))
    {
        consequent.execute(*this);
    }
}

/// Execute RUN statement
void InterpreterEngine::RUN()
{
    if (program.size() == 0)
    {
        showError("error: RUN - no program in memory");
        return;
    }

    programIndex = 0;
    clearVariablesAndArray();
    clearReturnStack();
    st = InterpreterStateRunning;
}

/// Execute END statement
void InterpreterEngine::END()
{
    st = InterpreterStateIdle;
}

/// Execute GOTO statement
void InterpreterEngine::GOTO(const Expression &expr)
{
    const auto lineNumber = evaluate(expr);
    const auto it = programLineWithNumber(lineNumber);
    if (it == program.end())
    {
        ostringstream s;
        s << "error: GOTO " << lineNumber << " - no line with that number";
        abortRunWithErrorMessage(s.str());
        return;
    }

    programIndex = distance(program.begin(), it);
    st = InterpreterStateRunning;
}

/// Execute GOSUB statement
void InterpreterEngine::GOSUB(const Expression &expr)
{
    const auto lineNumber = evaluate(expr);
    const auto it = programLineWithNumber(lineNumber);
    if (it == program.end())
    {
        ostringstream s;
        s << "error: GOSUB " << lineNumber << " - no line with that number";
        abortRunWithErrorMessage(s.str());
        return;
    }

    returnStack.push_back(programIndex);
    programIndex = distance(program.begin(), it);
    st = InterpreterStateRunning;
}

/// Execute RETURN statement
void InterpreterEngine::RETURN()
{
    if (returnStack.size() > 0)
    {
        programIndex = returnStack.back();
        returnStack.pop_back();
    }
    else
    {
        abortRunWithErrorMessage("error: RETURN - empty return stack");
    }
}

/// Execute CLEAR statement
void InterpreterEngine::CLEAR()
{
    clearProgram();
    clearReturnStack();
    clearVariablesAndArray();
}

/// Execute BYE statement
void InterpreterEngine::BYE()
{
    st = InterpreterStateIdle;
    [interpreter.io byeForInterpreter:interpreter];
}

/// Execute HELP statement
void InterpreterEngine::HELP()
{
    static const vec<string> lines = {
        "Enter a line number and a BASIC statement to add it to the program.  "
        "Enter a statement without a line number to execute it immediately.",
        "",
        "Statements:",
        "  BYE",
        "  CLEAR",
        "  CLIPLOAD",
        "  CLIPSAVE",
        "  END",
        "  FILES",
        "  GOSUB expression",
        "  GOTO expression",
        "  HELP",
        "  IF condition THEN statement",
        "  INPUT var-list",
        "  LET var = expression",
        "  LIST [firstLine [, lastLine]]",
        "  LOAD \"filename\"",
        "  PRINT expr-list",
        "  REM comment",
        "  RETURN",
        "  RUN",
        "  SAVE \"filename\"",
        "  TRON | TROFF",
        "",
        "Example:",
        "  10 print \"Hello, world!\"", "  20 end", "  list", "  run"};

    for (const auto &line : lines)
    {
        writeOutput(line);
        writeOutput('\n');
    }
}

/// Execute INPUT statement
void InterpreterEngine::INPUT(const Lvalues &lvalues)
{
    inputLvalues = lvalues;
    stateBeforeInput = st;
    [interpreter.io showInputPromptForInterpreter:interpreter];
    continueInput();
}

/// Display error message to user during an INPUT operation
void InterpreterEngine::showInputHelpMessage()
{
    if (inputLvalues.size() > 1)
    {
        auto s = ostringstream{};
        s << "You must enter a comma-separated list of " << inputLvalues.size()
          << " values.";
        showError(s.str());
    }
    else
    {
        showError("You must enter a value.");
    }

    [interpreter.io showInputPromptForInterpreter:interpreter];
}

/// Perform an INPUT operation
///
/// This may be called by INPUT(), or by next() if resuming an operation
/// following a .Waiting result from readInputLine()
void InterpreterEngine::continueInput()
{
    // Loop until successful or we hit end-of-input or a wait condition
    for (;;)
    {
    inputLoop:
        const auto inputLineResult = readInputLine();
        switch (inputLineResult.kind)
        {
            case InputResultKindValue:
            {
                auto pos = InputPos{inputLineResult.value, 0};

                auto first = bool{true};
                for (const auto &lv : inputLvalues)
                {
                    // If this is not the first value, need to see a comma
                    if (first)
                    {
                        first = false;
                    }
                    else
                    {
                        const auto comma = literal(",", pos);
                        if (comma.wasParsed())
                        {
                            pos = comma.nextPos();
                        }
                        else
                        {
                            showInputHelpMessage();
                            goto inputLoop;
                        }
                    }

                    const auto num = inputExpression(pos, *this);
                    if (num.wasParsed())
                    {
                        lv.setValue(num.value(), *this);
                        pos = num.nextPos();
                    }
                    else
                    {
                        showInputHelpMessage();
                        goto inputLoop;
                    }
                }

                // If we get here, we've read input for all the variables
                switch (stateBeforeInput)
                {
                    case InterpreterStateRunning:
                        st = InterpreterStateRunning;
                        break;
                    default:
                        st = InterpreterStateIdle;
                        break;
                }

                return;
            }
            break;

            case InputResultKindWaiting:
                st = InterpreterStateReadingInput;
                return;

            case InputResultKindEndOfStream:
                abortRunWithErrorMessage("error: INPUT - end of input stream");
                return;

            default:
                // Should be no other cases
                assert(false);
                abortRunWithErrorMessage("error: INPUT - invalid internal state");
                return;
        }
    }
}

/// Execute a DIM statement
void InterpreterEngine::DIM(const Expression &expr)
{
    const auto newCount = evaluate(expr);
    if (newCount < 0)
    {
        abortRunWithErrorMessage("error: DIM - size cannot be negative");
        return;
    }

    a.clear();
    a.resize(newCount, 0);
}

/// Execute a SAVE statement
void InterpreterEngine::SAVE(const string &filename)
{
    const auto file = fopen(filename.c_str(), "w");
    if (file)
    {
        for (const auto &line : program)
        {
            auto s = ostringstream{};
            s << line.lineNumber << " " << line.statement.listText() << "\n";
            const auto outputString = s.str();
            const char *outputChars = outputString.c_str();
            const auto outputLength = strlen(outputChars);
            fwrite(outputChars, 1, outputLength, file);
        }
        fclose(file);
    }
    else
    {
        auto s = ostringstream{};
        s << "error: SAVE - unable to open file \"" << filename << ": "
          << strerror(errno);
        abortRunWithErrorMessage(s.str());
    }
}

/// Execute a LOAD statement
void InterpreterEngine::LOAD(const string &filename)
{
    auto file = fopen(filename.c_str(), "r");
    if (file)
    {
        // Read lines until end-of-stream or error
        auto keepGoing = bool{true};
        do
        {
            const auto inputLineResult = getInputLine([file]() -> InputCharResult
                                                      {
                const auto c = fgetc(file);
                return c == EOF ? InputCharResult_EndOfStream() : InputCharResult_Value(c);
            });

            switch (inputLineResult.kind)
            {
                case InputResultKindValue:
                    processInput(inputLineResult.value);
                    break;

                case InputResultKindEndOfStream:
                    keepGoing = false;
                    break;

                default:
                    // getInputLine() for file should only return Value or EndOfStream
                    assert(false);
                    keepGoing = false;
                    break;
            }
        } while (keepGoing);

        // If we got an error, report it
        if (ferror(file) != 0)
        {
            auto s = ostringstream{};
            s << "error: LOAD - read error for file \"" << filename << ": "
              << strerror(errno);
            abortRunWithErrorMessage(s.str());
        }

        fclose(file);
    }
    else
    {
        auto s = ostringstream{};
        s << "error: LOAD - unable to open file \"" << filename << ": "
          << strerror(errno);
        abortRunWithErrorMessage(s.str());
    }
}

/// Execute a FILES statement
void InterpreterEngine::FILES()
{
    // Get working directory
    char wdbuf[MAXNAMLEN];
    const auto workingDirectory = getcwd(wdbuf, MAXNAMLEN);

    // Open the directory
    const auto dir = opendir(workingDirectory);
    if (dir)
    {
        // Use readdir to get each element
        auto dirent = readdir(dir);
        while (dirent)
        {
            // Only list files, not directories
            if (dirent->d_type != DT_DIR)
            {
                string name(dirent->d_name, dirent->d_namlen);
                writeOutput(name + "\n");
            }
            dirent = readdir(dir);
        }
        closedir(dir);
    }
}

/// Execute a CLIPSAVE statement
void InterpreterEngine::CLIPSAVE()
{
    const auto outputString = programAsString();
    if (outputString.empty())
    {
        abortRunWithErrorMessage("error: CLIPSAVE - no program in memory");
        return;
    }

    copyToPasteboard(outputString);
}

/// Execute a CLIPLOAD statement
void InterpreterEngine::CLIPLOAD()
{
    const auto s = getPasteboardContents();
    if (s.empty())
    {
        abortRunWithErrorMessage("error: CLIPLOAD - unable to read text from clipboard");
        return;
    }

    interpretString(s);
}


/// Execute a TRON statement
void InterpreterEngine::TRON()
{
    isTraceOn = true;
}

/// Execute a TROFF statement
void InterpreterEngine::TROFF()
{
    isTraceOn = false;
}

}  // namespace finchlib_cpp
