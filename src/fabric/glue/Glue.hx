package fabric.glue;

using haxe.macro.ComplexTypeTools;
using haxe.macro.TypeTools;
import haxe.macro.Printer;
import sys.FileSystem;
import haxe.macro.Context;
import haxe.macro.Expr;
class Glue {
    #if macro 
    public static function mixin(expr:Expr) {
        // Forbidden early typing
        var goodType = Context.typeof(expr).toComplexType();
        var name:String;
        switch (goodType) {
            case TPath(p) | TNamed(_, _ => TPath(p)):
                // Class<>
                name = p.name.substr(6, -1);
            default: 
                Context.error("Expected module path", Context.currentPos());
                return null;

        }
		
        var calledOn = Context.getLocalType();
        switch (calledOn) {
            case TInst(type, _): 
                var fields = haxe.macro.Context.getBuildFields();
                
                var imports = ["org.spongepowered.asm.mixin.Mixin", "org.spongepowered.asm.mixin.injection.At", "org.spongepowered.asm.mixin.injection.Inject", ];
                var modulePathList = type.get().module.split(".");
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
                                if (meta.name == "inject") {
                                    if (meta.params.length == 0)
                                        Context.error("Inject meta must have some args", meta.pos);
                                    hasMeta = true;
                                    theMeta = meta;
                                    break;
                                }
                            }
                            if (!hasMeta) continue;
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
                                                    case TPType(_ => TPath(p2)) | TPType(_ => TNamed(_,_ => TPath(p2) )):
                                                        params.push(javafySpecialTypes(p2));
                                                    default: 
                                                        Context.error("Invalid type paramater (it can only be a type path)", Context.currentPos());
                                                }
                                            }
                                        }
                                        argNames.push(arg.name);
                                        argTypes.push(p.name + if (params != null && params.length != 0) "<" + params.join(",")  + ">" else '');
									case null:
										Context.error("Injected functions type hints require explicit declaration", Context.currentPos());
                                    default: 
                                        Context.error("Injected functions typehints must be type paths", Context.currentPos());
								}   
                            }
                            var atExpr = theMeta.params[0];
                            var at;
                            switch (atExpr.expr) {
                                case EConst(c):
                                    switch (c) {
                                        case CString(s, kind):
                                            at = s;
                                        default: 
                                            Context.error("Expected String for at", Context.currentPos());
                                    }
                                default: 
									Context.error("Expected String for at", Context.currentPos());
                            }
                            var injectStatement = '@Inject(at = @At(${printer.printExpr(theMeta.params[0])}), method = ${printer.printExpr(theMeta.params[1])} ${if (theMeta.params.length > 2) ", cancellable =" + printer.printExpr(theMeta.params[2]) else ""})';
                            // Generate function that sends all its args to our haxe function
                            var theFunction = 'private static void ${f.name}(${[for (i in 0...argNames.length) argTypes[i] + " " + argNames[i]].join(",")}) {\n $ourTypeName.${f.name}(${argNames.join(",")});}';
                            functions.push(injectStatement + '\n' + theFunction);
                        case FVar(_, _) | FProp(_,_,_,_):
                            
                    }
                }
                var mixinMetaString = '@Mixin($name.class)';
                javaFile += '\n';
                javaFile += imports.map((s) -> 'import $s;').join("\n");
                javaFile += '\n';
                javaFile += mixinMetaString;
                javaFile += 'public abstract class ${type.get().name} { \n ${functions.join("\n")}}';
                
                if (!FileSystem.exists('./glue/main/java/${modulePathList.slice(0, -1).join("/")}')) 
					FileSystem.createDirectory('./glue/main/java/${modulePathList.slice(0, -1).join("/")}');
                sys.io.File.saveContent('./glue/main/java/${modulePathList.join("/")}.java', javaFile);
                // Dont actually change anything, this is only used to generate java files
                return null;
            case _: 
                return null;
        }
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