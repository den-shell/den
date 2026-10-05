pub const tokenizer = @import("tokenizer.zig");
pub const parser = @import("parser.zig");
pub const ast = @import("ast.zig");
pub const ast_builder = @import("ast_builder.zig");
pub const optimized_parser = @import("optimized_parser.zig");
/// Where lists, pipelines and compound commands begin and end.
pub const compound = @import("compound.zig");

pub const Tokenizer = tokenizer.Tokenizer;
pub const Token = tokenizer.Token;
pub const TokenType = tokenizer.TokenType;

pub const Parser = parser.Parser;

// Optimized parser for simple commands (fast path)
pub const OptimizedParser = optimized_parser.OptimizedParser;
pub const FastPathCommand = optimized_parser.SimpleCommand;
pub const StreamingTokenizer = optimized_parser.StreamingTokenizer;

// AST types
pub const Node = ast.Node;
pub const Script = ast.Script;
pub const SimpleCommand = ast.SimpleCommand;
pub const Pipeline = ast.Pipeline;
pub const List = ast.List;
pub const IfStatement = ast.IfStatement;
pub const ForLoop = ast.ForLoop;
pub const WhileLoop = ast.WhileLoop;
pub const CaseStatement = ast.CaseStatement;
pub const FunctionDef = ast.FunctionDef;
pub const Word = ast.Word;
pub const Redirection = ast.Redirection;
pub const Assignment = ast.Assignment;
pub const SourceLoc = ast.SourceLoc;
pub const Span = ast.Span;
pub const PrettyPrinter = ast.PrettyPrinter;

// AST Builder
pub const AstBuilder = ast_builder.AstBuilder;

// AST Optimizer
pub const ast_optimizer = @import("ast_optimizer.zig");
pub const AstOptimizer = ast_optimizer.AstOptimizer;
pub const optimizeAst = ast_optimizer.optimizeAst;
