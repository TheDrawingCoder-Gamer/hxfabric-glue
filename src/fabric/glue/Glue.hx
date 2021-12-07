package fabric.glue;

using haxe.macro.ComplexTypeTools;
using haxe.macro.TypeTools;
import haxe.macro.Printer;
import sys.FileSystem;
import haxe.macro.Context;
import haxe.macro.Expr;
using Lambda;
using StringTools;
typedef InjectOptions = {
    var at:String;
    var method:String;
    var ?cancellable:Bool;
}
class Glue {
    #if macro 
    public static function mixin() {
        var calledOnRaw = Context.getLocalClass();
        if (calledOnRaw == null) return null;
        var calledOn = calledOnRaw.get();
        if (calledOn.meta.has(":mixin")) {

			var mixinMeta = calledOn.meta.extract(":mixin")[0];
			var mixinValues:Map<String, Expr> = [];
            if (mixinMeta.params == null ) {
                Context.error("Arguments Expected for mixin meta", mixinMeta.pos);
            }
			if (mixinMeta.params.length == 1 && !mixinMeta.params[0].expr.match(EBinop(OpAssign, _, _))) {
				mixinValues.set("value", mixinMeta.params[0]);
			} else {
				for (param in mixinMeta.params) {
					switch (param.expr) {
						case EBinop(_ => OpAssign, _.expr => EConst(CIdent(ident)), value):
							mixinValues.set(ident, value);
						case _:
							Context.error("Expected assignment in mixin metadata", Context.currentPos());
							return null;
					}
				}
			}
			if (!mixinValues.exists("value")) {
				Context.error("Expected class name for the only argument or for value.", Context.currentPos());
			}
			var fields = haxe.macro.Context.getBuildFields();

			var imports = [
				"org.spongepowered.asm.mixin.Mixin",
				"org.spongepowered.asm.mixin.injection.At",
				"org.spongepowered.asm.mixin.injection.Inject",
			];
			var modulePathList = calledOn.module.split(".");
			var ourTypeName = modulePathList.join(".");
			modulePathList.insert(-1, "glue");

			var javaFile = 'package ${modulePathList.slice(0, -1).join(".")};';
			var functions:Array<String> = [];
			var printer = new Printer();
			for (f in fields) {
				switch (f.kind) {
					case FFun(fun):
						var hasMeta = false;
						var theMeta:Null<haxe.macro.Expr.MetadataEntry> = null;
						for (meta in f.meta) {
							if (meta.name == ":inject") {
								if (meta.params.length == 0)
									Context.error("Inject meta must have some args", meta.pos);
								hasMeta = true;
								theMeta = meta;
								break;
							}
						}
						if (!hasMeta)
							continue;
						if (!f.access.contains(APublic))
							Context.error("Injected functions must be public", Context.currentPos());
						if (!f.access.contains(AStatic)) {
							Context.error("Injected functions must be static", Context.currentPos());
						}
						var argNames:Array<String> = [];
						var argTypes:Array<String> = [];
						for (arg in fun.args) {
							// Direct comparison
							if (arg.opt == true) {
								Context.error("Injected functions must not have optional arguments", Context.currentPos());
							}
							// NOTE: This will require explicit typing for functions
							switch (arg.type) {
								case TPath(badP) | TNamed(_, _ => TPath(badP)):
									var goodEnum = arg.type.toType().toComplexType();
									var p;
									switch (goodEnum) {
										case TPath(goodP) | TNamed(_, _ => TPath(goodP)):
											p = goodP;
										default:
											return null;
									}
									var goodName = javafySpecialTypes(p);
									// TODO: Ensure sub isn't specified
									if (goodName == p.name && p.name != "String")
										if (p.pack.length == 0)
											imports.push(p.name)
										else
											imports.push(p.pack.join(".") + "." + p.name);
									var params:Null<Array<String>> = null;
									if (p.params != null) {
										params = [];
										for (param in p.params) {
											switch (param) {
												case TPType(_ => TPath(p2)) | TPType(_ => TNamed(_, _ => TPath(p2))):
													params.push(javafySpecialTypes(p2));
												default:
													Context.error("Invalid type paramater (it can only be a type path)", Context.currentPos());
											}
										}
									}
									argNames.push(arg.name);
									argTypes.push(p.name + if (params != null && params.length != 0) "<" + params.join(",") + ">" else '');
								case null:
									Context.error("Injected functions type hints require explicit declaration", Context.currentPos());
								default:
									Context.error("Injected functions typehints must be type paths", Context.currentPos());
							}
						}
						var nameToValue:Map<String, Expr> = [];
						for (expr in theMeta.params) {
							switch (expr.expr) {
								case EBinop(_ => OpAssign, ident, value):
									switch (ident.expr) {
										case EConst(_ => CIdent(name)):
											nameToValue.set(name, value);
										default:
											Context.error("Expected an identifier", Context.currentPos());
									}
								default:
									Context.error("Only assignments are supported for injection arguments. ", Context.currentPos());
							}
						}
						if (!nameToValue.exists("at") || !nameToValue.exists("method")) {
							Context.error("@inject requires 'at' and 'method' arguments", Context.currentPos());
						}
						var atValue = nameToValue.get("at");
						var methodValue = nameToValue.get("method");
						nameToValue.remove("at");
						nameToValue.remove("method");
						var injectStatement = '@Inject(at = @At(${printer.printExpr(atValue)}), method = ${printer.printExpr(methodValue)} ${if ([for (key in nameToValue.keys()) key].length != 0) "," + [for (key => value in nameToValue) key + " = " + value].join(",") else ""})';
						// Generate function that sends all its args to our haxe function
						var theFunction = 'private static void ${f.name}(${[for (i in 0...argNames.length) argTypes[i] + " " + argNames[i]].join(",")}) {\n $ourTypeName.${f.name}(${argNames.join(",")});}';
						functions.push(injectStatement + '\n' + theFunction);
                    default: 
				}
			}
			var mixinValueClass = mixinValues.get("value");
			mixinValues.remove("value");

			// class : )
			var mixinMetaString = '@Mixin(value = ${printer.printExpr(mixinValueClass)}.class ${if (mixinValues.count() != 0) "," + [for (key => value in mixinValues) key + " = " + printer.printExpr(value)].join(",") else ""})';
			javaFile += '\n';
			javaFile += imports.map((s) -> 'import $s;').join("\n");
			javaFile += '\n';
			javaFile += mixinMetaString;
			javaFile += 'public abstract class ${calledOn.name} { \n ${functions.join("\n")}}';

			if (!FileSystem.exists('./glue/main/java/${modulePathList.slice(0, -1).join("/")}'))
				FileSystem.createDirectory('./glue/main/java/${modulePathList.slice(0, -1).join("/")}');
			sys.io.File.saveContent('./glue/main/java/${modulePathList.join("/")}.java', javaFile);
			// Dont actually change anything, this is only used to generate java files
			return null;
        }
        return null;
    }
    /**
     * Returns java name if applicable
     * @param typepath 
     */
    private static function javafySpecialTypes(typepath:haxe.macro.Expr.TypePath) {
        if (typepath.pack.length == 0) {
            switch (typepath.name) {
                case "Bool": 
                    return "Boolean";
                case "String": 
                    return "String";
                case "Int": 
                    // TODO: Differentiate between java.lang.Int and regular int
                    return "int";
                default: 
                    return typepath.name;
            }
        }
        return typepath.name;
    }
    #end
}