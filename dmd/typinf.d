/**
 * Generate `TypeInfo` objects, which are needed for run-time introspection of classes.
 *
 * Copyright:   Copyright (C) 1999-2021 by The D Language Foundation, All Rights Reserved
 * Authors:     $(LINK2 http://www.digitalmars.com, Walter Bright)
 * License:     $(LINK2 http://www.boost.org/LICENSE_1_0.txt, Boost License 1.0)
 * Source:      $(LINK2 https://github.com/dlang/dmd/blob/master/src/dmd/typeinf.d, _typeinf.d)
 * Documentation:  https://dlang.org/phobos/dmd_typinf.html
 * Coverage:    https://codecov.io/gh/dlang/dmd/src/master/src/dmd/typinf.d
 */

module dmd.typinf;

import dmd.astenums;
import dmd.declaration;
import dmd.dmodule;
import dmd.dscope;
import dmd.dclass;
import dmd.dstruct;
import dmd.errors;
import dmd.globals;
import dmd.gluelayer;
import dmd.mtype;
import dmd.visitor;
import core.stdc.stdio;

/****************************************************
 * Generates the `TypeInfo` object associated with `torig` if it
 * hasn't already been generated
 * Params:
 *      loc   = the location for reporting line numbers in errors
 *      torig = the type to generate the `TypeInfo` object for
 *      sc    = the scope
 */
extern (C++) // IN_LLVM
void genTypeInfo(Loc loc, Type torig, Scope* sc)
{
    // printf("genTypeInfo() %s\n", torig.toChars());

    // Even when compiling without `useTypeInfo` (e.g. -betterC) we should
    // still be able to evaluate `TypeInfo` at compile-time, just not at runtime.
    // https://issues.dlang.org/show_bug.cgi?id=18472
    if (!sc || !(sc.flags & SCOPE.ctfe))
    {
        if (!global.params.useTypeInfo)
        {
            .error(loc, "`TypeInfo` cannot be used with -betterC");
            fatal();
        }
    }

    if (!Type.dtypeinfo)
    {
        .error(loc, "`object.TypeInfo` could not be found, but is implicitly used");
        fatal();
    }

    Type t = torig.merge2(); // do this since not all Type's are merge'd
    if (!t.vtinfo)
    {
        if (t.isShared()) // does both 'shared' and 'shared const'
            t.vtinfo = TypeInfoSharedDeclaration.create(t);
        else if (t.isConst())
            t.vtinfo = TypeInfoConstDeclaration.create(t);
        else if (t.isImmutable())
            t.vtinfo = TypeInfoInvariantDeclaration.create(t);
        else if (t.isWild())
            t.vtinfo = TypeInfoWildDeclaration.create(t);
        else
            t.vtinfo = getTypeInfoDeclaration(t);
        assert(t.vtinfo);

version (IN_LLVM)
{
        // LDC handles emission in the codegen layer
}
else
{
        /* If this has a custom implementation in std/typeinfo, then
         * do not generate a COMDAT for it.
         */
        if (!builtinTypeInfo(t))
        {
            // Generate COMDAT
            if (sc) // if in semantic() pass
            {
                // Find module that will go all the way to an object file
                Module m = sc._module.importedFrom;
                m.members.push(t.vtinfo);
            }
            else // if in obj generation pass
            {
                toObjFile(t.vtinfo, global.params.multiobj);
            }
        }
} // !IN_LLVM
    }
    if (!torig.vtinfo)
        torig.vtinfo = t.vtinfo; // Types aren't merged, but we can share the vtinfo's
    assert(torig.vtinfo);
}

/****************************************************
 * Gets the type of the `TypeInfo` object associated with `t`
 * Params:
 *      loc = the location for reporting line nunbers in errors
 *      t   = the type to get the type of the `TypeInfo` object for
 *      sc  = the scope
 * Returns:
 *      The type of the `TypeInfo` object associated with `t`
 */
extern (C++) Type getTypeInfoType(Loc loc, Type t, Scope* sc)
{
    assert(t.ty != Terror);
    genTypeInfo(loc, t, sc);
    return t.vtinfo.type;
}

private TypeInfoDeclaration getTypeInfoDeclaration(Type t)
{
    //printf("Type::getTypeInfoDeclaration() %s\n", t.toChars());
    switch (t.ty)
    {
    case Tpointer:
        return TypeInfoPointerDeclaration.create(t);
    case Tarray:
        return TypeInfoArrayDeclaration.create(t);
    case Tsarray:
        return TypeInfoStaticArrayDeclaration.create(t);
    case Taarray:
        return TypeInfoAssociativeArrayDeclaration.create(t);
    case Tstruct:
        return TypeInfoStructDeclaration.create(t);
    case Tvector:
        return TypeInfoVectorDeclaration.create(t);
    case Tenum:
        return TypeInfoEnumDeclaration.create(t);
    case Tfunction:
        return TypeInfoFunctionDeclaration.create(t);
    case Tdelegate:
        return TypeInfoDelegateDeclaration.create(t);
    case Ttuple:
        return TypeInfoTupleDeclaration.create(t);
    case Tclass:
        if ((cast(TypeClass)t).sym.isInterfaceDeclaration())
            return TypeInfoInterfaceDeclaration.create(t);
        else
            return TypeInfoClassDeclaration.create(t);

    default:
        return TypeInfoDeclaration.create(t);
    }
}

version (IN_LLVM)
{
    // LDC handles TypeInfo emission in the codegen layer
    // => no need to take care of speculative types.
}
else
{

/**************************************************
 * Returns:
 *      true if any part of type t is speculative.
 *      if t is null, returns false.
 */
bool isSpeculativeType(Type t)
{
    static bool visitVector(TypeVector t)
    {
        return isSpeculativeType(t.basetype);
    }

    static bool visitAArray(TypeAArray t)
    {
        return isSpeculativeType(t.index) ||
               isSpeculativeType(t.next);
    }

    static bool visitStruct(TypeStruct t)
    {
        StructDeclaration sd = t.sym;
        if (auto ti = sd.isInstantiated())
        {
            if (!ti.needsCodegen())
            {
                if (ti.minst || sd.requestTypeInfo)
                    return false;

                /* https://issues.dlang.org/show_bug.cgi?id=14425
                 * TypeInfo_Struct would refer the members of
                 * struct (e.g. opEquals via xopEquals field), so if it's instantiated
                 * in speculative context, TypeInfo creation should also be
                 * stopped to avoid 'unresolved symbol' linker errors.
                 */
                /* When -debug/-unittest is specified, all of non-root instances are
                 * automatically changed to speculative, and here is always reached
                 * from those instantiated non-root structs.
                 * Therefore, if the TypeInfo is not auctually requested,
                 * we have to elide its codegen.
                 */
                return true;
            }
        }
        else
        {
            //assert(!sd.inNonRoot() || sd.requestTypeInfo);    // valid?
        }
        return false;
    }

    static bool visitClass(TypeClass t)
    {
        ClassDeclaration sd = t.sym;
        if (auto ti = sd.isInstantiated())
        {
            if (!ti.needsCodegen() && !ti.minst)
            {
                return true;
            }
        }
        return false;
    }


    static bool visitTuple(TypeTuple t)
    {
        if (t.arguments)
        {
            foreach (arg; *t.arguments)
            {
                if (isSpeculativeType(arg.type))
                    return true;
            }
        }
        return false;
    }

    if (!t)
        return false;
    Type tb = t.toBasetype();
    switch (tb.ty)
    {
        case Tvector:   return visitVector(tb.isTypeVector());
        case Taarray:   return visitAArray(tb.isTypeAArray());
        case Tstruct:   return visitStruct(tb.isTypeStruct());
        case Tclass:    return visitClass(tb.isTypeClass());
        case Ttuple:    return visitTuple(tb.isTypeTuple());
        case Tenum:     return false;
        default:
        return isSpeculativeType(tb.nextOf());

        /* For TypeFunction, TypeInfo_Function doesn't store parameter types,
         * so only the .next (the return type) is checked here.
         */
    }
}

} // !IN_LLVM

/* ========================================================================= */

/* These decide if there's an instance for them already in std.typeinfo,
 * because then the compiler doesn't need to build one.
 */
// IN_LLVM: replaced `private` with `extern(C++)`
extern(C++) bool builtinTypeInfo(Type t)
{
    // IN_LLVM: the Tclass case seems to be a DMD hack
    //          (in order not to define ClassInfos in each referencing module)
    if (t.isTypeBasic() || (!IN_LLVM && t.ty == Tclass) || t.ty == Tnull)
        return !t.mod;
    if (t.ty == Tarray)
    {
        Type next = t.nextOf();
        // strings are so common, make them builtin
        return !t.mod &&
               (next.isTypeBasic() !is null && !next.mod ||
                next.ty == Tchar && next.mod == MODFlags.immutable_ ||
                next.ty == Tchar && next.mod == MODFlags.const_);
    }
    return false;
}
