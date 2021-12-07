# Haxe Fabric Glue
A macro library that automagically generates mixin "glue" that connects to haxe mixin definitions

## Caveats

The real "mixin" library is in the `glue` submodule, relative to where the mixin definition is. Thus, in your jsons, you must add `.glue` to the end of the `package`. A way to get around this would be to swap the positioning but that sounds like an absolute nightmare. 

## Usage

To mark a class as a mixin class, add mixin metadata.
```hx
@:mixin(path.to.Class)
```
To have other parameters (like priority) you can do something like this:
```hx
@:mixin(value = path.to.Class, priority = 200)
```

Inject is the only kind of metadata supported for functions. 
`at` and `method` are required; at is equal to what would be inside the `@At` annotation and method is equivilant to it's java counterpart: 
```hx
@:inject(at = "HEAD", method = "init()V")
```
Other parameters are outputted as if they were normally printed; Most should work however not everything is tested.

Functions must have explicit typing; These are automatically converted to java types and imports, which are required for it to work. Not everything is tested so some issues may occur. They also must be public and static; when overwriting a static function you must add an `@:static` meta. Otherwise it assumes you are overwriting a non static function.

With the haxe fabric template everything is automatically handled; all that's needed is to install the haxelib. 
