package fabric.glue;

import sys.io.File;
import haxe.macro.Compiler;
using haxe.macro.ComplexTypeTools;
using haxe.macro.TypeTools;
import haxe.macro.Printer;
import sys.FileSystem;
import haxe.macro.Context;
import haxe.macro.Expr;
import haxe.macro.Expr.ComplexType;
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
        // Accessor/Invokers and injections don't mix!
        if (calledOn.meta.has(":mixin")) {

			var mixinMeta = calledOn.meta.extract(":mixin")[0];
			var mixinString = javafyMixinMeta(mixinMeta);
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
						var isStatic = false;
						for (meta in f.meta) {
							if (meta.name == ":inject") {
								if (meta.params.length == 0)
									Context.error("Inject meta must have some args", meta.pos);
								hasMeta = true;
								theMeta = meta;
							}
							if (meta.name == ":static") {
								isStatic = true;
							}
						}
						if (!hasMeta)
							continue;
						if (!f.access.contains(APublic))
							Context.error("Injected functions must be public", Context.currentPos());
						if (!f.access.contains(AStatic))
							Context.error("Injected functions must be static", Context.currentPos());
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
						var theFunction = 'private ${if (isStatic) "static" else ""} void ${f.name}(${[for (i in 0...argNames.length) argTypes[i] + " " + argNames[i]].join(",")}) {\n $ourTypeName.${f.name}(${argNames.join(",")});}';
						functions.push(injectStatement + '\n' + theFunction);
                    default: 
				}
			}

			// class : )
			var mixinMetaString = mixinString;
			javaFile += '\n';
			javaFile += imports.map((s) -> 'import $s;').join("\n");
			javaFile += '\n';
			javaFile += mixinMetaString.str;
			javaFile += 'public abstract class ${calledOn.name} { \n ${functions.join("\n")}}';

			if (!FileSystem.exists('./glue/main/java/${modulePathList.slice(0, -1).join("/")}'))
				FileSystem.createDirectory('./glue/main/java/${modulePathList.slice(0, -1).join("/")}');
			sys.io.File.saveContent('./glue/main/java/${modulePathList.join("/")}.java', javaFile);
			// Dont actually change anything, this is only used to generate java files
			return null;
        } else if (!calledOn.meta.has(":mixin")) {
            Context.error("Glue Mixin implementers must have @:mixin metadata", Context.currentPos());
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
                    // TODO: Differentiate between java.lang.Integer and regular int
                    return "int";
                default: 
                    return typepath.name;
            }
        }
        return typepath.name;
    }
    private static function javafyMixinMeta(metadata:MetadataEntry):{str:String, values:Map<String, Expr>} {
        var printer = new Printer();
        if (metadata.name != ":mixin") {
            throw "Expected mixin meta (Internal error, you are real stupid for doing this bulby)";
        }
        if (metadata.params == null || metadata.params.length == 0) {
            Context.error("Expected arguments for @:mixin metadata", metadata.pos);
            return null;
        }
        var mixinValues:Map<String, Expr> = [];
        switch (metadata.params[0].expr) {
            case EBinop(_ => OpAssign, _, _):
                for (param in metadata.params) {
                    switch (param.expr) {
                        case EBinop(_ => OpAssign, e1, e2):
                            mixinValues.set(printer.printExpr(e1), e2);
                        default: 
                            Context.error("Expected assignment as metadata argument", metadata.pos);
                            return null;
                    }
                }
            default: 
                if (metadata.params.length > 1) {
                    Context.error("Expected assignment as metadata argument", metadata.pos);
                    return null;
                }
                mixinValues.set("value", metadata.params[0]);

        }
        if (!mixinValues.exists("value")) {
            Context.error("value must be defined for mixin metadata", metadata.pos);
        }
        return {str: '@Mixin(${[for (key => value in mixinValues) key + " = " + printer.printExpr(value) + (key == "value" ? ".class" : "")].join(",")})', values:mixinValues};
    }
    private static function javafyTypePath(typepath:TypePath):String {
        var workingType = Reflect.copy(typepath);
        var params = null;
		if (workingType.params != null && workingType.params.length != 0) {
			params = [];
            for (param in workingType.params) {
                switch (param) {
                    case TPType(t):
                        switch (t) {
                            case TPath(p):
                                params.push(javafyTypePath(p));
                            default: 
                                // cry about it
                        }
                    default: 
                        // also cry about
                }
            }
        }
		var tempName = workingType.pack.length != 0 ? workingType.pack.join(".") + "." + workingType.name : workingType.name;
        switch (tempName + (workingType.sub != null ? "." + workingType.sub : "")) {
            case "StdTypes.Bool": 
                return "Boolean";
            case "StdTypes.String" | "java.NativeString": 
                return "String";
            case "StdTypes.Int": 
                return "int";
            case "StdTypes.Void": 
                return "void";
            case "java.NativeArray": 
                return params[0] + "[]";
            case "StdTypes.Array": 
                Context.warning("Javafying a haxe array; Did you mean to use a java.NativeArray?", Context.currentPos());
                return params[0] + "[]";
            case "StdTypes.Class":
                return params[0] + ".class";
        }
        return tempName + (if (params != null) "<" + params.join(",") + ">" else "") ;
    }
    public static function accessor() {
        var calledOnRaw = Context.getLocalClass();
        if (calledOnRaw == null) {
            Context.error("Expected class for implementer of GlueAccessor", Context.currentPos());
            return null;
        }
        var calledOn = calledOnRaw.get();
        if (!calledOn.meta.has(":mixin")) {
            Context.error("Accessor class must have @:mixin metadata", Context.currentPos());
            return null; 
        }

        var mixinMeta = calledOn.meta.extract(":mixin")[0];
        var mixinData = javafyMixinMeta(mixinMeta);
        var glueFields = [];
        var buildFields = Context.getBuildFields();
		var newFields = [];
        var gluePack = calledOn.pack.concat(["glue"]);
        var printer = new Printer();
        for (f in buildFields) {
			if (!f.meta.exists((i) -> i.name == ":accessor")) {
                Context.warning("This field doesn't have an accessor metadata; Did you mean to add one?", Context.currentPos());
                newFields.push(f);
                continue;
            }
				
			var accessorMeta = f.meta.find((i) -> i.name == ":accessor");
			var name:String = f.name; 
            switch (f.kind) {
                case FProp(g, s, type, expr):
                    if ((g != "get" && g != "never") || (s != "set" && s != "never")) {
                        Context.error("Accessor property may only have get, set, or never.", Context.currentPos());
                        continue;
                    }
                    if (g == "never" && s == "never") { 
                        continue;
                    }
                    if (accessorMeta.params != null && accessorMeta.params.length > 0) {
						switch (accessorMeta.params[0].expr) {
                            case EConst(_ => CString(str, _)):
                                name = str;
                            default: 
                                Context.error("Expected string name as parameter", accessorMeta.pos);
                                continue;
                        }
                    }
                    if (!f.access.has(AStatic)) {
                        Context.error("Non static properties must use functions", Context.currentPos());
                        continue;
                    }
                    if (s == "set" && g != "get") {
                        Context.error("Setter requires a getter", Context.currentPos());
                        continue;
                    }
                    newFields.push(f);
					var newGetName = "get_" + name;
                    // If it has get
                    if (g == "get") {
                        var getName = "get" + name;
                        var getClass = macro class Dummy {
                            @:glueGetter
                            extern public static function $getName ();
                        }
                        var getField = getClass.fields[0];
                        getField.meta.push(accessorMeta);
                        switch (getField.kind) {
                            case FFun(f):
                                f.ret = type;
                                getField.kind = FFun(f);
                            default: 
                                // shouldn't happen???
                        }
                        glueFields.push(getField);
                    
                        
						// Statically access with fields. No I do not know what I am doing
						var newGetClass = macro class Dummy {
							inline public static function $newGetName() {
								return $p{gluePack.concat([${calledOn.name}, ${getName}])}();
							}
						}
                        newFields.push(newGetClass.fields[0]);
                    }
                    if (s == "set" ) {
                        var setName = "set" + name; 

                        var setClass = macro class Dummy {
                            @:glueSetter
                            extern public static function $setName(input):Void;
                        }

                        var setField = setClass.fields[0];
                        setField.meta.push(accessorMeta);
                        switch (setField.kind) {
                            case FFun(f):
                                f.args[0].type = type;
                                setField.kind = FFun(f);
                            default: 
                                // shouldn't happen?
                        }
						glueFields.push(setField);
                        var newSetName = "set_" + name; 
                        var newSetClass = macro class Dummy {
                            inline public static function $newSetName(input) {
								$p{gluePack.concat([${calledOn.name}, ${setName}])}(input);
                                return $i{name};
                            }
                        }
                        newFields.push(newSetClass.fields[0]);
                    }
                case FFun(fun): 
                    if (f.access.contains(AStatic)) {
                        Context.error("Static accessors must be properties", Context.currentPos());
                        continue;
                    }
                    if (fun.ret == null) {
                        Context.error("Expected explicit type declaration", Context.currentPos());
                        continue;
                    }
                    if (accessorMeta.params == null || accessorMeta.params.length != 1) {
                        Context.error("Accessor functions must have 1 argument that is a string.", accessorMeta.pos);
                        continue;
                    }  
                    switch (accessorMeta.params[0].expr) {
                        case EConst(_ => CString(str)):
                            name = str;

                        default: 
                            Context.error("Expected string as only argument", Context.currentPos());
                            continue;
                    }
                    var fieldName = f.name;
					if (fun.args.length == 0 && !fun.ret.match(TPath(_.name => "Void"))) {
                        // Get
                        var glueGet = macro class Dummy {
                            @:glueGetter
                            extern public function $fieldName();
                        }
                        var getField = glueGet.fields[0];
                        getField.meta.push(accessorMeta);
                        switch (getField.kind){ 
                            case FFun(fun2):
                                fun2.ret = fun.ret;
                                getField.kind = FFun(fun2);
                            default: 
                                // Shouldn't happen?
                        }
                        
                        glueFields.push(getField);
                        var newGet = macro class Dummy {
                            inline public static function $fieldName(instance);
                        }
                        var newGetField = newGet.fields[0];
                        newGetField.meta = [accessorMeta];
						var funnyMixinPath:TypePath = {pack: [], name: ""};
						var classThing = mixinData.values.get("value");
						function funnyFunction(value:Expr) {
							switch (value.expr) {
								case EField(e, field):
									funnyMixinPath.pack.unshift(field);
									funnyFunction(e);
								case EConst(_ => CIdent(id)):
									funnyMixinPath.pack.unshift(id);
								default:
									Context.error("expected a typepath : (", Context.currentPos());
							}
						};
						funnyFunction(classThing);
						funnyMixinPath.name = funnyMixinPath.pack.pop();
						switch (newGetField.kind) {
							case FFun(fun2):
								// This is called sadism
								// stop this madness
								fun2.expr = {
									pos: Context.currentPos(),
									expr: EReturn({
										pos: Context.currentPos(),
										expr: ECall({
											expr: EField({
												expr: ECast({
													pos: Context.currentPos(),
													expr: EConst(CIdent("instance"))
												}, TPath({pack: gluePack, name: calledOn.name})),
												pos: Context.currentPos()
											}, fieldName),
											pos: Context.currentPos()
										}, [])
									})
								};
                                fun2.args[0].type = TPath(funnyMixinPath);
								newGetField.kind = FFun(fun2);
                                
							default:
						}
						
                        
                        newFields.push(newGetField);


                    } else if (fun.args.length == 1 && fun.ret.match(TPath(_.name => "Void"))) {
                        // Set
						var glueSet = macro class Dummy {
                            @:glueSetter
							extern public function $fieldName(input):Void;
						}
						var setField = glueSet.fields[0];
                        setField.meta.push(accessorMeta);
						switch (setField.kind) {
							case FFun(fun2):
								fun2.args[0].type = fun.args[0].type;

								setField.kind = FFun(fun2);
							default:
								// Shouldn't happen?
						}
						glueFields.push(setField);
						var newSet = macro class Dummy {
                            @:accessor()
							inline public static function $fieldName(instance, input):Void;
						}
						var newSetField = newSet.fields[0];
                        newSetField.meta = [accessorMeta];

						switch (newSetField.kind) {
							case FFun(fun2):
								// This is called sadism
								// stop this madness
								fun2.expr = {
									pos: Context.currentPos(),
									expr: ECall({
										expr: EField({
											expr: ECast({
												pos: Context.currentPos(),
												expr: EConst(CIdent("instance"))
											}, TPath({pack: gluePack, name: calledOn.name})),
											pos: Context.currentPos()
										}, fieldName),
										pos: Context.currentPos()
									}, [{pos: Context.currentPos(), expr: EConst(CIdent("input"))}])
								};
                                var funnyMixinPath:TypePath = {pack: [], name: ""};
								var classThing = mixinData.values.get("value");
                                function funnyFunction (value:Expr) {
                                    switch (value.expr) {
                                        case EField(e, field):
                                            funnyMixinPath.pack.unshift(field);
                                            funnyFunction(e);
                                        case EConst(_ => CIdent(id)):
                                            funnyMixinPath.pack.unshift(id);
                                        default: 
                                            Context.error("expected a typepath : (", Context.currentPos());
                                    }   
                                };
                                funnyFunction(classThing);
                                funnyMixinPath.name = funnyMixinPath.pack.pop();
                                fun2.args[0].type = TPath(funnyMixinPath);
								newSetField.kind = FFun(fun2);
							default:
						}
						newFields.push(newSetField);
                    } else {
                        // :sob:
                        Context.error("Not a valid get or set accessor; Getters have no args and a non void return type, Setters have 1 arg and a void return type.", Context.currentPos());
                        continue;
                    }


                default: 
                    Context.error("Accessor classes may not contain normal variables .", Context.currentPos());
                    continue;
            }
        }
        var className = calledOn.name;
        var glueInterface = macro interface $className {

        };
        glueInterface.isExtern = true;
        for (glueField in glueFields) {
            glueInterface.fields.push(glueField);
        }
        // This doesn't actually have the fields
        Context.defineModule(gluePack.concat([className]).join("."), [glueInterface]);
        // WARNING: DO NOT READ IF YOU DO NOT WANT ANEURISM
        // well if you got here you've prob already had one :sweat_smile: sowwy

        var javaFile = 'package ${gluePack.join(".")};';
        javaFile += '\nimport java.lang.AssertionError;';
        javaFile += '\nimport org.spongepowered.asm.mixin.gen.Accessor;';
        javaFile += '\nimport org.spongepowered.asm.mixin.Mixin;';
        javaFile += '\n${mixinData.str}';
        javaFile += '\npublic interface $className {\n';
        for (field in glueFields) {
            if (!field.meta.exists((it) -> it.name == ":accessor"))
                // I made a big oopsie ignore it to cause frustration for when this fails
                continue;
			var theMeta = field.meta.find((it) -> it.name == ":accessor");
			if (theMeta.params == null || theMeta.params.length != 1) {
				Context.error("Expected string (probably internal error)", Context.currentPos());
				continue;
			}
			var daName:String;
			switch (theMeta.params[0].expr) {
				case EConst(_ => CString(s, _)):
					daName = s;
				default:
					Context.error("Internal error; Expected string as first parameter", Context.currentPos());
					continue;
			}

			javaFile += '@Accessor("$daName")\n';

			if (field.meta.exists((it) -> it.name == ":glueGetter")) {
				var daTypeName;
				switch (field.kind) {
					case FFun(f):
						// FORBIDDEN TYPE :flushed:
						// This (afaik) fully expands type name
						var funnyType = f.ret.toType().toComplexType();
						switch (funnyType) {
							case TPath(p):
								daTypeName = p;
							default:
								Context.error("Expected type path for return typehint", Context.currentPos());
								continue;
						}
					default:
				}
                if (field.access.contains(AStatic)) {
					javaFile += 'public static ${javafyTypePath(daTypeName)} ${field.name}() {\n';
					javaFile += 'throw new AssertionError(); \n}\n';
                } else {
                    javaFile += 'public ${javafyTypePath(daTypeName)} ${field.name}();\n';
                }
				
			} else {
				// setter or pray
				var daTypeName;
				switch (field.kind) {
					case FFun(f):
						// fully expands type name : )
						var funnyType = f.args[0].type.toType().toComplexType();
						switch (funnyType) {
							case TPath(p):
								daTypeName = p;
							default:
								Context.error("Expected type path for argument typehint", Context.currentPos());
								continue;
						}
					default:
				}
                if (field.access.contains(AStatic)) {
					javaFile += 'public static void ${field.name}(${javafyTypePath(daTypeName)} input) {\n';
					javaFile += 'throw new AssertionError(); \n}\n';
                } else {
                    javaFile += 'public void ${field.name}(${javafyTypePath(daTypeName)} input);\n';
                }
				
			}
        }
        javaFile += '}';
		if (!FileSystem.exists('./glue/main/java/${gluePack.join("/")}'))
			FileSystem.createDirectory('./glue/main/java/${gluePack.join("/")}');
		sys.io.File.saveContent('./glue/main/java/${gluePack.concat([className]).join("/")}.java', javaFile);
        return newFields; 
    }
    #end
}