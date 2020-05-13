package jsasync.impl;

#if macro
import sys.io.File;
import haxe.macro.Compiler;
import haxe.macro.Context;
import haxe.macro.Expr;

using haxe.macro.ExprTools;

class Macro {
	static var helper = macro jsasync.impl.Helper;
	static var jsasyncClass = macro jsasync.JSAsync;
	static var jsSyntax = macro js.Syntax;

	/** Implementation of JSAsync.func macro */
	static public function asyncFuncMacro(e : Expr) {
		// Convert FArrow into FAnonymous
		switch(e.expr) {
			case EFunction(FArrow, f):
				f.expr = macro return ${f.expr};
				e.expr = EFunction(FAnonymous, f);
			default:
		}

		switch(e.expr) {
			case EFunction(FAnonymous, f): f.expr = modifyFunctionBody(f.expr);
			default: Context.error("Argument should be an anonymous function of arrow function", e.pos);
		}
		return macro ${helper}.makeAsync(${e});
	}

	/** Implementation of JSAsync.build macro */
	static public function build():Array<Field> {
		var c = Context.getLocalClass();
		if ( c == null ) return null;
		var c = c.get();
		if ( c.meta.has(":jsasync_processed") ) return null;
		c.meta.add(":jsasync_processed", [], Context.currentPos());

		var fields = Context.getBuildFields();

		for ( field in fields ) {
			var m = Lambda.find(field.meta, m -> m.name == ":jsasync");
			if ( m == null ) continue;

			switch(field.kind) {
				case FFun(func):
					func.expr = modifyMethodBody(func.expr);
				default:
			}
		}

		return fields;
	}

	static function useMarkers() {
		var useMarkers = !Context.defined("jsasync-no-markers");
		if ( useMarkers ) registerFixOutputFile();
		return useMarkers;
	}

	/** Modifies a function body so that all return expressions are wrapped by Helper.wrapReturn */
	static function wrapReturns(e : Expr) {
		var found = false;

		function mapFunc(e: Expr) {
			return switch(e.expr) {
				case EReturn(sub): 
					if ( sub != null ) {
						found = true;
						macro @:pos(p(e.pos)) return ${helper}.wrapReturn(${sub.map(mapFunc)});
					}else {
						makeReturnNothingExpr(e.pos);
					}
				case EFunction(kind, f): e; // Don't modify returns inside other functions
				default: e.map(mapFunc);
			}
		}

		return {
			expr: mapFunc(e),
			found: found
		};
	}

	/** For some reason using @:pos during display tends to break completion, this is a work around for that.
		It's likely that this is a bug in the haxe compiler.
		TODO: try to make smaller code sample that reproduces this bug. */
	static function p(pos:Position) {
		return Context.defined("display")? Context.currentPos() : pos;
	}

	/** Converts a function body to turn it into an async function */
	static function modifyFunctionBody(e:Expr) {
		var wrappedReturns = wrapReturns(e);

		var insertReturn = if ( wrappedReturns.found ) {
			macro @:pos(p(e.pos)) {}
		}else {
			makeReturnNothingExpr(e.pos, useMarkers()? "%%async_nothing%%" : "");
		}

		return macro {
			${wrappedReturns.expr};
			${insertReturn};
		}
	}

	static function makeReturnNothingExpr(pos: Position, returnCode: String = "") {
		return macro @:pos(p(pos)) return ${helper}.makeNothingPromise(${jsSyntax}.code($v{returnCode}));
	}

	static function modifyMethodBody(e:Expr) {
		var body = modifyFunctionBody(e);
		return if (useMarkers()) {
			macro {
				${jsSyntax}.code("%%async_marker%%");
				${body}
			};
		}else {
			macro return ${helper}.makeAsync(function() ${body})();
		}
	}

	static var fixOutputFileRegistered = false;
	static function registerFixOutputFile() {
		if ( !fixOutputFileRegistered && !Context.defined("display") ) {
			Context.onAfterGenerate( fixOutputFile );
			fixOutputFileRegistered = true;
		}
	}

	/** 
		Modifies the js output file.
		Adds "async" to functions marked with %%async_marker%% and removes "return %%async_nothing%%;"
	*/
	static function fixOutputFile() {
		if ( Context.defined("jsasync-no-fix-pass") || Sys.args().indexOf("--no-output") != -1 ) return;
		var output = Compiler.getOutput();
		var markerRegEx = ~/((?:"(?:[^"\\]|\\.)*"|\w+)\s*\([^()]*\)\s*{[^{}]*?)\s*%%async_marker%%;/g;
		var returnNothingRegEx = ~/\s*return %%async_nothing%%;/g;
		var outputContent = sys.io.File.getContent(output);
		outputContent = markerRegEx.replace(outputContent, "async $1");
		outputContent = returnNothingRegEx.replace(outputContent, "");
		File.saveContent(output, outputContent);
	}
}
#end