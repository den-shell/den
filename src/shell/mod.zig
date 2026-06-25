//! Shell module - modular shell components for Den
//!
//! This module provides:
//! - Version detection for various languages/tools
//! - Builtin command implementations
//! - Loop execution (C-style for, select)
//! - Directory stack management
//! - Printf formatting

pub const version = @import("version.zig");
pub const builtins = @import("builtins.zig");
pub const loops = @import("loops.zig");
pub const directory_stack = @import("directory_stack.zig");
pub const printf_builtin = @import("printf_builtin.zig");
pub const test_builtin = @import("test_builtin.zig");
pub const variable_builtins = @import("variable_builtins.zig");
pub const completion_builtins = @import("completion_builtins.zig");
pub const shopt_builtin = @import("shopt_builtin.zig");
pub const process_builtins = @import("process_builtins.zig");
pub const enable_builtin = @import("enable_builtin.zig");
pub const misc_builtins = @import("misc_builtins.zig");
pub const eval_builtins = @import("eval_builtins.zig");
pub const loop_execution = @import("loop_execution.zig");
pub const function_definition = @import("function_definition.zig");
pub const prompt_context = @import("prompt_context.zig");
pub const command_expansion = @import("command_expansion.zig");
pub const variable_handling = @import("variable_handling.zig");
pub const command_execution = @import("command_execution.zig");
pub const builtin_dispatch = @import("builtin_dispatch.zig");
pub const tab_completion = @import("tab_completion.zig");

// Re-export version detection functions for convenience
pub const detectPackageVersion = version.detectPackageVersion;
pub const detectBunVersion = version.detectBunVersion;
pub const detectNodeVersion = version.detectNodeVersion;
pub const detectPythonVersion = version.detectPythonVersion;
pub const detectRubyVersion = version.detectRubyVersion;
pub const detectGoVersion = version.detectGoVersion;
pub const detectRustVersion = version.detectRustVersion;
pub const detectZigVersion = version.detectZigVersion;

// Re-export builtin functions for convenience
pub const builtinHistory = builtins.builtinHistory;
pub const builtinAlias = builtins.builtinAlias;
pub const builtinUnalias = builtins.builtinUnalias;
pub const builtinType = builtins.builtinType;
pub const builtinWhich = builtins.builtinWhich;
pub const builtinHelp = builtins.builtinHelp;
pub const builtinBasename = builtins.builtinBasename;
pub const builtinDirname = builtins.builtinDirname;
pub const builtinRealpath = builtins.builtinRealpath;
pub const builtinUname = builtins.builtinUname;
pub const builtinWhoami = builtins.builtinWhoami;
pub const builtinClear = builtins.builtinClear;
pub const builtinSleep = builtins.builtinSleep;
pub const builtinReturn = builtins.builtinReturn;
pub const builtinBreak = builtins.builtinBreak;
pub const builtinContinue = builtins.builtinContinue;

// Re-export directory stack functions
pub const builtinPushd = directory_stack.builtinPushd;
pub const builtinPopd = directory_stack.builtinPopd;
pub const builtinDirs = directory_stack.builtinDirs;
pub const rotateDirStack = directory_stack.rotateDirStack;
pub const printDirStack = directory_stack.printDirStack;

// Re-export printf functions
pub const builtinPrintf = printf_builtin.builtinPrintf;

// Re-export test functions
pub const builtinTest = test_builtin.builtinTest;
pub const matchRegex = test_builtin.matchRegex;

// Re-export variable builtin functions
pub const builtinLocal = variable_builtins.builtinLocal;
pub const builtinDeclare = variable_builtins.builtinDeclare;
pub const builtinReadonly = variable_builtins.builtinReadonly;
pub const builtinTypeset = variable_builtins.builtinTypeset;
pub const builtinLet = variable_builtins.builtinLet;
pub const printDeclare = variable_builtins.printDeclare;
pub const setVarAttributes = variable_builtins.setVarAttributes;

// Re-export completion builtin functions
pub const builtinComplete = completion_builtins.builtinComplete;
pub const builtinCompgen = completion_builtins.builtinCompgen;
pub const printCompletionSpec = completion_builtins.printCompletionSpec;
pub const showLegacyCompletions = completion_builtins.showLegacyCompletions;

// Re-export shopt builtin function
pub const builtinShopt = shopt_builtin.builtinShopt;

// Re-export zsh-style setopt/unsetopt builtins
pub const setopt_builtin = @import("setopt_builtin.zig");
pub const builtinSetopt = setopt_builtin.builtinSetopt;
pub const builtinUnsetopt = setopt_builtin.builtinUnsetopt;

// Re-export AI completion builtin
pub const ai_builtin = @import("ai_builtin.zig");
pub const builtinAi = ai_builtin.builtinAi;

// Re-export WebAssembly plugin builtin
pub const wasm_builtin = @import("wasm_builtin.zig");
pub const builtinWasm = wasm_builtin.builtinWasm;

// Re-export process builtin functions
pub const builtinExec = process_builtins.builtinExec;
pub const builtinKill = process_builtins.builtinKill;

// Re-export enable builtin function
pub const builtinEnable = enable_builtin.builtinEnable;

// Re-export misc builtin functions
pub const builtinSource = misc_builtins.builtinSource;
pub const builtinMapfile = misc_builtins.builtinMapfile;
pub const builtinTime = misc_builtins.builtinTime;
pub const builtinHash = misc_builtins.builtinHash;
pub const builtinUmask = misc_builtins.builtinUmask;
pub const builtinCaller = misc_builtins.builtinCaller;

// Re-export eval builtin functions
pub const builtinRead = eval_builtins.builtinRead;
pub const builtinCommand = eval_builtins.builtinCommand;
pub const builtinEval = eval_builtins.builtinEval;
pub const builtinShift = eval_builtins.builtinShift;
pub const builtinBuiltin = eval_builtins.builtinBuiltin;

// Re-export loop execution functions
pub const executeCStyleForLoopOneline = loop_execution.executeCStyleForLoopOneline;
pub const executeCStyleLoopBodyCommand = loop_execution.executeCStyleLoopBodyCommand;
pub const executeWithCStyleForLoop = loop_execution.executeWithCStyleForLoop;
pub const executeSelectLoop = loop_execution.executeSelectLoop;
pub const executeSelectBody = loop_execution.executeSelectBody;
pub const executeArithmeticStatement = loop_execution.executeArithmeticStatement;
pub const setArithVariable = loop_execution.setArithVariable;
pub const evaluateArithmeticCondition = loop_execution.evaluateArithmeticCondition;
pub const evaluateArithmeticExpr = loop_execution.evaluateArithmeticExpr;
pub const getVariableValueForArith = loop_execution.getVariableValueForArith;

// Re-export function definition functions
pub const checkFunctionDefinitionStart = function_definition.checkFunctionDefinitionStart;
pub const handleMultilineContinuation = function_definition.handleMultilineContinuation;
pub const finishFunctionDefinition = function_definition.finishFunctionDefinition;
pub const resetMultilineState = function_definition.resetMultilineState;

// Re-export prompt context functions
pub const renderPrompt = prompt_context.renderPrompt;
pub const getPromptString = prompt_context.getPromptString;
pub const updatePromptContext = prompt_context.updatePromptContext;

// Re-export command expansion functions
pub const expandCommandChain = command_expansion.expandCommandChain;
pub const expandCommand = command_expansion.expandCommand;
pub const expandAliases = command_expansion.expandAliases;

// Re-export variable handling functions
pub const resolveNameref = variable_handling.resolveNameref;
pub const getVariableValue = variable_handling.getVariableValue;
pub const setVariableValue = variable_handling.setVariableValue;
pub const isArrayAssignment = variable_handling.isArrayAssignment;
pub const executeArrayAssignment = variable_handling.executeArrayAssignment;
pub const isArrayElementAssignment = variable_handling.isArrayElementAssignment;
pub const executeArrayElementAssignment = variable_handling.executeArrayElementAssignment;
pub const executeAssocArrayAssignment = variable_handling.executeAssocArrayAssignment;
pub const isAssocArrayElementAssignment = variable_handling.isAssocArrayElementAssignment;
pub const executeAssocArrayElementAssignment = variable_handling.executeAssocArrayElementAssignment;

// Re-export command execution functions
pub const tryFastPath = command_execution.tryFastPath;
pub const executeErrTrap = command_execution.executeErrTrap;
pub const executeExitTrap = command_execution.executeExitTrap;
pub const executeInBackground = command_execution.executeInBackground;

// Re-export builtin dispatch
pub const dispatchBuiltin = builtin_dispatch.dispatchBuiltin;
pub const isShellBuiltin = builtin_dispatch.isShellBuiltin;
pub const DispatchResult = builtin_dispatch.DispatchResult;

// Re-export tab completion functions
pub const tabCompletionFn = tab_completion.tabCompletionFn;
pub const setCompletionConfig = tab_completion.setCompletionConfig;
pub const getCompletionConfig = tab_completion.getCompletionConfig;
