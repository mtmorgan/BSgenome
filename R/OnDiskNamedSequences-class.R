### =========================================================================
### OnDiskNamedSequences objects
### -------------------------------------------------------------------------


setClass("OnDiskNamedSequences")  # VIRTUAL class with no slots

### OnDiskNamedSequences API
### ------------------------
### Concrete subclasses need to implement the following:
###   - names()
###   - seqlengthsFilepath()
###   - seqinfo API (implementing seqinfo() is enough to make seqlengths(),
###                  seqlevels(), etc... work)
###   - [[ -- load full sequence as XString object
### Default methods are provided for the following:
###   - length()
###   - seqnames()
###   - show()
###   - loadSubseqsFromLinearSequence()

setGeneric("seqlengthsFilepath",
    function(x) standardGeneric("seqlengthsFilepath")
)

setGeneric("loadSubseqsFromLinearSequence",
    function(x, seqname, ranges)
        standardGeneric("loadSubseqsFromLinearSequence")
)

### Low-level utilities

### Works on an XString object or any object 'x' for which seqlengths() is
### defined.
.get_seqlength <- function(x, seqname)
{
    if (!isSingleString(seqname))
        stop("'seqname' must be a single string")
    if (is(x, "XString"))
        return(length(x))
    x_seqlengths <- seqlengths(x)
    idx <- match(seqname, names(x_seqlengths))
    if (is.na(idx))
        stop("invalid sequence name: ", seqname)
    x_seqlengths[[idx]]
}

### Default methods

setMethod("length", "OnDiskNamedSequences", function(x) length(names(x)))

setMethod("seqnames", "OnDiskNamedSequences", function(x) seqlevels(x))

setMethod("show", "OnDiskNamedSequences",
    function(object)
    {
        cat(class(object), " instance of length ", length(object),
            ":\n", sep="")
        GenomeInfoDb:::compactPrintNamedAtomicVector(seqlengths(object))
    }
)

### Load regions from a single sequence as an XStringSet object.

### 'seqname' is ignored.
setMethod("loadSubseqsFromLinearSequence", "XString",
    function(x, seqname, ranges)
        xvcopy(extractAt(x, ranges))  # ignores 'seqname'
)

setMethod("loadSubseqsFromLinearSequence", "OnDiskNamedSequences",
    function(x, seqname, ranges)
        loadSubseqsFromLinearSequence(x[[seqname]], seqname, ranges)
)


### - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
### RdaNamedSequences objects
###
### The "dirpath" slot should contain 1 serialized XString object per
### sequence + a serialized named integer vector ('seqlengths.rda')
### containing the sequence names and lengths.
###

setClass("RdaNamedSequences",
    contains=c("RdaCollection", "OnDiskNamedSequences"),
    representation(
        seqlengths="RdaCollection"
    )
)

setMethod("seqlengthsFilepath", "RdaNamedSequences",
    function(x) rdaPath(x@seqlengths, "seqlengths")
)

setMethod("seqlevels", "RdaNamedSequences", function(x) names(x))

setMethod("seqlengths", "RdaNamedSequences",
    function(x)
    {
        ans <- x@seqlengths[["seqlengths"]]
        if (!is.integer(ans) || is.null(names(ans)))
            stop("serialized object in file '", seqlengthsFilepath(x), "' ",
                 "must be a named integer vector")
        ans
    }
)

setMethod("seqinfo", "RdaNamedSequences",
    function(x)
    {
        x_seqlengths <- seqlengths(x)
        x_seqlevels <- seqlevels(x)
        Seqinfo(x_seqlevels, x_seqlengths)
    }
)

### Constructor.
RdaNamedSequences <- function(dirpath, seqnames)
{
    sequences <- RdaCollection(dirpath, seqnames)
    seqlengths <- RdaCollection(dirpath, "seqlengths")
    new("RdaNamedSequences", sequences, seqlengths=seqlengths)
}

### Load a full sequence as an XString object.
setMethod("[[", "RdaNamedSequences",
    function(x, i, j, ...)
    {
        ans <- callNextMethod()
        if (!is(ans, "XString"))
            stop("serialized object in file '", rdaPath(x, i), "' ",
                 "must be an XString object")
        updateObject(ans)
    }
)


### - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
### FastaNamedSequences objects
###

setClass("FastaNamedSequences",
    contains="OnDiskNamedSequences",
    representation(
        ## FaFile object pointing to the .fa/.fa.fai (or .fa.rz/.fa.rz.fai
        ## if RAZip compressed) files containing the sequences/index.
        fafile="FaFile"
    )
)

setMethod("names", "FastaNamedSequences", function(x) seqlevels(x@fafile))

setMethod("seqlengthsFilepath", "FastaNamedSequences",
    function(x) path(x@fafile)
)

setMethod("seqinfo", "FastaNamedSequences", function(x) seqinfo(x@fafile))

### Constructor.
FastaNamedSequences <- function(filepath)
{
    fafile <- FaFile(filepath)
    open(fafile)
    new("FastaNamedSequences", fafile=fafile)
}

### We only support subetting by name.
### Load a full sequence as a DNAString object.
setMethod("[[", "FastaNamedSequences",
    function(x, i, j, ...)
    {
        if (!missing(j) || length(list(...)) > 0L)
            stop("invalid subsetting")
        if (!is.character(i))
            stop("a FastaNamedSequences object can only be subsetted by name")
        if (length(i) < 1L)
            stop("attempt to select less than one element")
        if (length(i) > 1L)
            stop("attempt to select more than one element")
        fafile <- x@fafile
        seqlength <- .get_seqlength(fafile, i)
        param <- GRanges(i, IRanges(1L, seqlength))
        scanFa(fafile, param=param)[[1L]]
    }
)

### Load regions from a single sequence as a DNAStringSet object.
### TODO: Try the following optimization: reduce 'ranges' before calling
### scanFa(), then extract the regions from the DNAStringSet returned by
### scanFa(). This way, a given nucleotide is loaded only once.
setMethod("loadSubseqsFromLinearSequence", "FastaNamedSequences",
    function(x, seqname, ranges)
    {
        if (!is(ranges, "IntegerRanges"))
            stop("'ranges' must be an IntegerRanges object")
        fafile <- x@fafile
        seqlength <- .get_seqlength(fafile, seqname)
        if (length(ranges) != 0L &&
            (min(start(ranges)) < 1L || max(end(ranges)) > seqlength))
            stop("trying to load regions beyond the boundaries ",
                 "of non-circular sequence \"", seqname, "\"")
        param <- GRanges(seqname, ranges)
        scanFa(fafile, param=param)
    }
)


### - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
### TwobitNamedSequences objects
###

setClass("TwobitNamedSequences",
    contains="OnDiskNamedSequences",
    representation(
        ## TwoBitFile object pointing to the .2bit file containing the
        ## sequences.
        twobitfile="TwoBitFile"
    )
)

setMethod("names", "TwobitNamedSequences", function(x) seqlevels(x@twobitfile))

setMethod("seqlengthsFilepath", "TwobitNamedSequences",
    function(x) path(x@twobitfile)
)

setMethod("seqinfo", "TwobitNamedSequences", function(x) seqinfo(x@twobitfile))

### Constructor.
TwobitNamedSequences <- function(filepath)
{
    twobitfile <- TwoBitFile(filepath)
    new("TwobitNamedSequences", twobitfile=twobitfile)
}

### We only support subetting by name.
### Load a full sequence as a DNAString object.
setMethod("[[", "TwobitNamedSequences",
    function(x, i, j, ...)
    {
        if (!missing(j) || length(list(...)) > 0L)
            stop("invalid subsetting")
        if (!is.character(i))
            stop("a FastaNamedSequences object can only be subsetted by name")
        if (length(i) < 1L)
            stop("attempt to select less than one element")
        if (length(i) > 1L)
            stop("attempt to select more than one element")
        twobitfile <- x@twobitfile
        seqlength <- .get_seqlength(twobitfile, i)
        which <- GRanges(i, IRanges(1L, seqlength))
        import(twobitfile, which=which)[[1L]]
    }
)

### Load regions from a single sequence as a DNAStringSet object.
setMethod("loadSubseqsFromLinearSequence", "TwobitNamedSequences",
    function(x, seqname, ranges)
    {
        if (!is(ranges, "IntegerRanges"))
            stop("'ranges' must be an IntegerRanges object")
        twobitfile <- x@twobitfile
        seqlength <- .get_seqlength(twobitfile, seqname)
        if (length(ranges) != 0L &&
            (min(start(ranges)) < 1L || max(end(ranges)) > seqlength))
            stop("trying to load regions beyond the boundaries ",
                 "of non-circular sequence \"", seqname, "\"")
        which <- GRanges(seqname, ranges)
        import(twobitfile, which=which)
    }
)


### - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
### loadSubseqsFromStrandedSequence()
###

.loadSubseqsFromCircularSequence <- function(x, seqname, ranges)
{
    if (!is(ranges, "IntegerRanges"))
        stop("'ranges' must be an IntegerRanges object")
    seqlength <- .get_seqlength(x, seqname)
    LRranges <- splitLRranges(ranges, seqlength, seqname)
    Lans <- loadSubseqsFromLinearSequence(x, seqname, LRranges$L)
    Rans <- loadSubseqsFromLinearSequence(x, seqname, LRranges$R)
    xscat(Lans, Rans)
}

loadSubseqsFromStrandedSequence <- function(x, seqname, ranges, strand,
                                            is_circular=NA)
{
    if (length(ranges) != length(strand))
        stop("'ranges' and 'strand' must have the same length")
    if (!is.logical(is_circular) || length(is_circular) != 1L)
        stop("'is_circular' must be a single logical")
    if (is_circular %in% c(NA, FALSE)) {
        loadFUN <- loadSubseqsFromLinearSequence
    } else {
        loadFUN <- .loadSubseqsFromCircularSequence
    }
    ans <- loadFUN(x, seqname, ranges)
    idx <- which(strand == "-")
    ans[idx] <- reverseComplement(ans[idx])
    ans
}

