## TODO: Elsewhere run a tryCatch over this to uniformly add the
## target name to the error.
make_target <- function(name, dat, extra=NULL) {
  assert_scalar_character(name)
  if (name %in% target_reserved_names()) {
    stop(sprintf("Target name %s is reserved", name))
  }

  ## This is just a wrapper function to improve the traceback on error.
  make_target_dat <- function(dat) {
    assert_named_list(dat, name="target data")
    dat <- process_target_command(name, dat)
    generators <- list(object=target_new_object,
                       file=target_new_file,
                       plot=target_new_plot,
                       knitr=target_new_knitr,
                       fake=target_new_fake,
                       cleanup=target_new_cleanup)
    type <- match_value(dat$type, names(generators))
    generators[[type]](name, dat$command, dat$opts, extra)
  }

  prefix <- sprintf("While processing target '%s':\n    ", name)
  withCallingHandlers(make_target_dat(dat),
                      error=catch_error_prefix(prefix),
                      warning=catch_warning_prefix(prefix))
}

target_new_base <- function(name, command, opts, extra=NULL,
                            type="base", valid_options=NULL) {
  assert_scalar_character(name)
  assert_scalar_character(type)
  if ("target_argument" %in% names(command) && type != "file") {
    stop("'target_argument' field invalid for arguments of type ", type)
  }
  valid_options <- c("type", "quiet", "check", "packages", valid_options)
  stop_unknown(name, opts, valid_options)

  ret <- list(name=name, type=type)
  ret$command <- command$command
  ret$status_string <- ""

  if (!is.null(command$rule)) {
    assert_scalar_character(command$rule, "rule")
    ret$rule <- command$rule
  }

  ret$depends_name <- with_default(unname(command$depends), character(0))
  ret$arg_is_target <- with_default(command$is_target, logical(0))
  if (any(duplicated(ret$depends_name))) {
    stop("Dependency listed more than once")
  }
  if (any(duplicated(setdiff(names(command$args), "")))) {
    stop("All named depends targets must be unique")
  }

  ret$cleanup_level <- with_default(opts$cleanup_level, "never")
  ret$cleanup_level <-
    match_value(ret$cleanup_level, cleanup_levels(), "cleanup_level")

  ret$quiet <- with_default(opts$quiet, FALSE)
  assert_scalar_logical(ret$quiet, "quiet")

  ret$check <- with_default(opts$check, "all")
  ret$check <- match_value(ret$check, check_levels(), "check")

  if ("packages" %in% names(opts)) {
    ret$packages <- opts$packages
    assert_character(opts$packages)
  }

  if ("chain" %in% names(command)) {
    chain <- target_chain(command$chain, ret, opts)
    ret <- chain$parent
    ret$chain_kids <- chain$kids
  }

  class(ret) <- "target_base"
  ret
}

target_new_object <- function(name, command, opts, extra=NULL,
                              valid_options=NULL) {
  if (is.null(command$rule)) {
    stop("Must not have a NULL rule")
  }
  opts$cleanup_level <- with_default(opts$cleanup_level, "tidy")
  valid_options <- c("cleanup_level", valid_options)
  ret <- target_new_base(name, command, opts, extra, "object", valid_options)
  ret$status_string <- "BUILD"
  class(ret) <- c("target_object", class(ret))
  ret
}

target_new_file <- function(name, command, opts, extra=NULL,
                            valid_options=NULL) {
  if (is.null(command$rule)) {
    stop("Must not have a NULL rule")
  }
  opts$cleanup_level <- with_default(opts$cleanup_level, "clean")
  valid_options <- c("cleanup_level", valid_options)
  ret <- target_new_base(name, command, opts, extra, "file", valid_options)
  ret$target_argument <- command$target_argument
  ret$status_string <- "BUILD"
  class(ret) <- c("target_file", class(ret))
  ret
}

## This is called directly by remake, and skips going through
## target_new_base.  That will probably change back shortly.
target_new_file_implicit <- function(name, check_exists=TRUE) {
  if (check_exists && !file.exists(name)) {
    warning("Creating implicit target for nonexistant file ", name)
  }
  ret <- list(name=name,
              type="file",
              depends_name=character(0),
              depends_type=character(0),
              arg_is_target=logical(0),
              implicit=TRUE,
              cleanup_level="never",
              check="exists")
  class(ret) <- c("target_file_implicit", "target_file") # not target_base
  ret
}

target_new_plot <- function(name, command, opts, extra=NULL) {
  if (is.null(command$rule)) {
    stop("Cannot have a NULL rule")
  }
  ret <- target_new_file(name, command, opts, extra, "plot")
  ##  ret$plot <- opts$plot # checked at activate()

  dev <- get_device(tools::file_ext(name))
  plot_args <- opts$plot
  if (identical(plot_args, TRUE) || is.null(plot_args)) {
    plot_args <- empty_named_list()
  } else if (is.character(plot_args) && length(plot_args) == 1) {
    if (plot_args %in% names(extra$plot_options)) {
      plot_args <- extra$plot_options[[plot_args]]
    } else {
      stop(sprintf("Unknown plot_options '%s' in target '%s'",
                   plot_args, name))
    }
  }
  assert_named_list(plot_args)

  ## This will not work well for cases where `...` is in the
  ## device name (such as jpeg, bmp, etc), but we can work around that
  ## later.
  warn_unknown("plot", plot_args, names(formals(dev)))
  ret$plot <- list(device=dev, args=plot_args)

  ret$status_string <- "PLOT"
  class(ret) <- c("target_plot", class(ret))
  ret
}

target_new_knitr <- function(name, command, opts, extra=NULL) {
  if (!is.null(command$rule)) {
    stop(sprintf("%s: knitr targets must have a NULL rule",
                 name))
  }
  opts$quiet <- with_default(opts$quiet, TRUE)

  ## Then the knitr options:
  knitr <- opts$knitr
  if (identical(knitr, TRUE) || is.null(knitr)) {
    knitr <- empty_named_list()
  } else if (is.character(knitr) && length(knitr) == 1) {
    if (knitr %in% names(extra$knitr_options)) {
      knitr <- extra$knitr_options[[knitr]]
    } else {
      stop(sprintf("Unknown knitr_options '%s' in target '%s'",
                   knitr, name))
    }
  }
  assert_named_list(knitr)
  warn_unknown("knitr", knitr,
               c("input", "options", "chdir", "auto_figure_prefix"))

  ## Infer name if it's not present:
  if (is.null(knitr$input)) {
    knitr$input <- knitr_infer_source(name)
  }
  assert_scalar_character(knitr$input)

  knitr$auto_figure_prefix <-
    with_default(knitr$auto_figure_prefix, FALSE)
  assert_scalar_logical(knitr$auto_figure_prefix)

  knitr$chdir <- with_default(knitr$chdir, FALSE)
  assert_scalar_logical(knitr$chdir)

  ## NOTE: It might be useful to set fig.path here, so that we can
  ## work out what figures belong with different knitr targets.
  ## What I'm going to do though is *not* do that at the moment
  ## though.  Better would be to have a key (e.g.,
  ## fig.path.disambiguate) that indicate that the prefix should
  ## be set using the fig_default_fig_path function.  Then the
  ## default gets the same behaviour as default knitr.
  if (is.null(knitr$options)) {
    knitr$options <- list()
  }
  if (knitr$auto_figure_prefix && !is.null(knitr$options$fig.path)) {
    warning("Ignoring 'auto_figure_prefix' in favour of 'fig.path'")
    knitr$auto_figure_prefix <- FALSE
  }
  ## By default we *will* set error=FALSE.  It's hard to imagine a
  ## workflow where that is not what is wanted.  Better might be
  ## to allow the compilation to continue but detect if there was
  ## an error and throw an error at the target level though.
  if (is.null(knitr$options$error)) {
    knitr$options$error <- FALSE
  }

  ## Remember any mapping here:
  ## Build a dependency on the input, for obvious reasons
  command$depends <- c(command$depends, knitr$input)

  ## Hack to let target_base know we're not implicit.  There does
  ## need to be something here as a few places test for null-ness.
  command$rule <- ".__knitr__"
  ret <- target_new_file(name, command, opts, extra, "knitr")

  class(ret) <- c("target_knitr", class(ret))
  ret$knitr <- knitr
  ## TODO: This isolates some ugliness for now, but should be done via
  ## opts or extra probably.
  if (!is.null(names(command$depends))) {
    ret$depends_rename <- command$depends
  }
  
  ret
}

target_new_cleanup <- function(name, command, opts, extra=NULL) {
  ret <- target_new_base(name, command, opts, extra, "cleanup")
  ret$status_string <- "CLEAN"
  class(ret) <- c("target_cleanup", class(ret))
  ret
}

target_new_fake <- function(name, command, opts, extra=NULL) {
  if (!is.null(command$rule)) {
    stop("fake targets must have a NULL rule (how did you do this?)")
  }
  ret <- target_new_base(name, command, opts, extra, "fake")
  ret$status_string <- "-----"
  class(ret) <- c("target_fake", class(ret))
  ret
}

## Determine if things are up to date.  That is the case if:
##
## If the file/object does not exist it's unclean (done)
##
## If it has no dependencies it is clean (done) (no phoney targets)
##
## If the hashes of all inputs are unchanged from last time, it is clean
##
## Otherwise unclean
target_is_current <- function(target, store, check=NULL) {
  check <- with_default(check, target$check)
  check <- match_value(check, check_levels())

  if (target$type %in% c("cleanup", "fake")) {
    return(FALSE)
  } else if (!store$contains(target$name, target$type)) {
    return(FALSE)
  } else if (is.null(target$rule)) {
    return(TRUE)
  } else if (!store$db$contains(target$name)) {
    ## This happens when a file target exists, but there is no record
    ## of it being created (such as when the .remake directory is
    ## deleted or if it comes from elsewhere).  In which case we can't
    ## tell if it's up to date and assume not.
    ##
    ## *However* if check is 'exists', then this is enough because we
    ## don't care about the code or the dependencies.
    return(check == "exists")
  } else {
    ## TODO: This is all being done at once.  However, if we implement
    ## a compare_dependency_status() function, we can do this
    ## incrementally, returning FALSE as soon as the first failure is
    ## found.
    ##
    ## TODO: Need options for deciding what to check (existance, data,
    ## code).
    return(compare_dependency_status(
      store$db$get(target$name),
      dependency_status(target, store, missing_ok=TRUE, check=check),
      check))
  }
}

dependency_status <- function(target, store, missing_ok=FALSE, check=NULL) {
  check <- with_default(check, target$check)
  depends <- fixed <- code <- NULL

  if (check_depends(check)) {
    depends_type <- target$depends_type
    depends_name <- target$depends_name
    keep <- depends_type %in% c("file", "object")
    depends <- lapply(which(keep), function(i)
                      store$get_hash(depends_name[[i]],
                                     depends_type[[i]], missing_ok))
    names(depends) <- depends_name[keep]

    ## Then, get the non-target dependencies, too.  We don't do this
    ## as a map list because order is guaranteed.
    is_fixed <- !target$arg_is_target
    if (any(is_fixed)) {
      fixed_vars <- as.list(target$command[-1][is_fixed])
      fixed <- hash_object(lapply(fixed_vars, eval, store$env$env))
    }
  }

  if (check_code(check)) {
    code <- store$env$deps$info(target$rule)
  }

  ## Here, missing_ok needs to be true I think, or we can't ask about
  ## the status of things that don't exist yet; it's different to the
  ## previous missing_ok's which are about upstream dependencies.
  hash <- store$get_hash(target$name, target$type, TRUE)

  list(version=store$version,
       name=target$name,
       type=target$type,
       hash=hash,
       time=Sys.time(),
       depends=depends,
       fixed=fixed,
       code=code)
}

compare_dependency_status <- function(prev, curr, check) {
  ## Here, if we need to deal with different version information we
  ## can.  One option will be to deprecate previous versions.  So say
  ## we change the format, or hash algorithms, or something and no
  ## longer allow version 0.1.  We'd say:
  ##
  ##   expire <- package_version("0.0")
  ##   if (prev$version <= expire) {
  ##     warning(sprintf("Expiring object %s (version: %s)",
  ##                     prev$name, prev$version))
  ##     return(FALSE)
  ##   }
  ## TODO: This check is not actually needed here.
  check <- match_value(check, check_levels())
  ok <- TRUE

  if (check_depends(check)) {
    ok <- ok && identical_map(prev$depends, curr$depends)
    ok <- ok && identical(prev$fixed, curr$fixed)
  }
  if (check_code(check)) {
    ## TODO: I've dropped checking *packages* here: see #13
    ok <- ok && identical_map(prev$code$functions, curr$code$functions)
  }

  ok
}

## Not recursive:
identical_map <- function(x, y) {
  nms <- names(x)
  length(x) == length(y) && all(nms %in% names(y)) && identical(y[nms], x)
}

## There aren't many of these yet; might end up with more over time
## though.
target_reserved_names <- function() {
  c("target_name", ".")
}

## TODO: There is an issue here for getting options for rules that
## terminate in knitr or plot rules: we can't pass along options to
## these!
##
##   Always accept quiet, check, packages (base)
##     cleanup_level (file and object)
##   never plot, knitr, auto_figure_prefix
##
## Special testing will be required to get that right.  Basically only
## the terminating bit of rule here will accept nonstandard options.
target_chain <- function(chain, parent, opts) {
  if (!(parent$type %in% c("file", "object"))) {
    stop("Can't use chained rules on targets of type ", parent)
  }
  len <- length(chain)
  chain_names <- chained_rule_name(parent$name, seq_len(len))
  parent <- target_chain_match_dot(parent, len + 1L, chain_names)

  ## TODO: Duplication of object valid options here.
  opts_chain <- opts[names(opts) %in%
                     c("quiet", "check", "packages", "cleanup_level")]
  f <- function(i) {
    x <- target_new_object(chain_names[[i]], chain[[i]], opts_chain)
    x$chain_parent <- parent
    target_chain_match_dot(x, i, chain_names)
  }

  kids <- lapply(seq_len(len), f)
  list(parent=parent, kids=kids)
}

target_chain_match_dot <- function(target, pos, chain_names) {
  j <- which(as.character(target$depends_name) == ".")
  if (length(j) == 1L) {
    if (j > length(chain_names)) {
      stop("Attempt to select impossible chain element") # defensive only
    }
    dot_name <- chain_names[[pos - 1L]]
    target$depends_name[[j]] <- dot_name
    target$command[[j + 1L]] <- as.name(dot_name)
  } else { # defensive - should be safe here.
    if (length(j) > 1L) {
      stop("never ok")
    } else if (pos > 1L) {
      stop("missing")
    }
  }
  target
}

make_target_cleanup <- function(name, remake) {
  levels <- cleanup_target_names()
  name <- match_value(name, levels)

  dat <- list(command=NULL, depends=character(0), quiet=FALSE, type="cleanup")
  if (name %in% names(remake$targets)) {
    t <- remake$targets[[name]]

    ## These aren't tested:
    if (!is.null(t$chain_kids)) {
      stop("Cleanup target cannot contain a chain")
    }
    if (length(t$command) > 1L) {
      stop("Cleanup target commands must have no arguments")
    }
    dat$command <- t$command
    dat$depends <- t$depends_name # watch out
    dat$quiet   <- t$quiet
  }

  i <- match(name, levels)
  if (i > 1L) {
    dat$depends <- c(dat$depends, levels[[i - 1L]])
  }

  ret <- make_target(name, dat)

  ## Add the actual bits to clean, making sure to exclude things
  ## destined to become cleanup targets.
  target_level <- vcapply(remake$targets, function(x) x$cleanup_level)
  ret$targets_to_remove <-
    setdiff(names(remake$targets)[target_level == name], levels)
  ret
}

chained_rule_name <- function(name, i) {
  sprintf("%s{%d}", name, i)
}

check_levels <- function() {
  c("all", "code", "depends", "exists")
}

check_code <- function(x) {
  x %in% c("all", "code")
}
check_depends <- function(x) {
  x %in% c("all", "depends")
}

target_get <- function(target, store) {
  if (target$type == "file") {
    target$name
  } else if (target$type == "object") {
    store$objects$get(target$name)
  } else {
    stop("Not something that can be got")
  }
}
target_set <- function(target, store, value) {
  if (target$type == "file") {
    ## NOTE: value ignored here, will be NULL probably.
    store$db$set(target$name,
                 dependency_status(target, store, check="all"))
  } else if (target$type == "object") {
    store$objects$set(target$name, value)
    ## NOTE: Must do *after* setting the object, because we'll look up
    ## the hash in a during dependency_status
    store$db$set(target$name,
                 dependency_status(target, store, check="all"))
  } else {
    stop("Not something that can be set")
  }
}

## This whole section is a bit silly, but will save some confusion
## down the track.  Basically; file targets must be quoted, object
## targets must not be.  This lets us mimic R calls.  It's not
## actually required by any of the parsing machinery, but it means the
## files will be easier to interpret.  It *is* requred for making
## valid scripts though.
target_check_quoted <- function(target) {
  i <- target$arg_is_target
  if (any(i)) {
    args <- as.list(target$command[-1])
    is_quoted <- vlapply(args[i], is.character)
    should_be_quoted <-
      target$depends_type[vcapply(args[i], as.character)] == "file"

    if (any(should_be_quoted != is_quoted)) {
      nms <- names(should_be_quoted)
      err_quote <-  should_be_quoted & !is_quoted
      err_plain <- !should_be_quoted &  is_quoted
      msg <- character(0)
      if (any(err_quote)) {
        msg <- c(msg, paste("Should be quoted:",
                            paste(nms[err_quote], collapse=", ")))
      }
      if (any(err_plain)) {
        msg <- c(msg, paste("Should not be quoted:",
                            paste(nms[err_plain], collapse=", ")))
      }
      stop(sprintf("Incorrect quotation in target '%s':\n%s",
                   target$name, paste(msg, collapse="\n")))
    }
  }
}

## Might compute these things at startup, given they are constants
## over the life of the object.
target_run_fake <- function(target, for_script=FALSE) {
  if (is.null(target$rule) || target$type == "cleanup") {
    NULL
  } else {
    ## TODO: Get a test on this - was a weird error because this
    ## caused lines to break over multiple lines and therefore did not
    ## print properly with remake_print_message().
    res <- paste(deparse(target$command, width.cutoff=500L), collapse=" ")
    if (inherits(target, "target_plot")) {
      if (for_script) {
        open <- plot_call(target$name, target$plot$device, target$plot$args)
        res <- c(deparse(open), res, "dev.off()")
      } else {
        res <- paste(res, "# ==>", target$name)
      }
    } else if (inherits(target, "target_knitr")) {
      res <- sprintf('knitr::knit("%s", "%s")',
                     target$knitr$input, target$name)
    } else if (target$type == "object") {
      ## This is a trick to ensure correct printing of the LHS of the
      ## assigmnent; it will keep the backticks around the LHS
      ## variable names only when they're required syntactically
      ## (they're already around the rhs).
      target_name <- deparse(parse(text=sprintf("`%s`", target$name))[[1]],
                             backtick=TRUE)
      res <- sprintf("%s <- %s", target_name, res)
    }

    if (for_script && !is.null(target$packages)) {
      res <- c(sprintf('library("%s")', target$packages), res)
    }

    res
  }
}

target_build <- function(target, store, quiet=NULL) {
  if (target$type == "file") {
    if (is.null(target$rule)) {
      ## NOTE: Not sure this is desirable - should just pass?
      stop("Can't build implicit targets")
    }
    ## This avoids either manually creating directories, or obscure
    ## errors when R can't save a file to a place.  Possibly this
    ## should be a configurable behaviour, but we're guaranteed to
    ## be working with genuine files so this should be harmless.
    dir.create(dirname(target$name), showWarnings=FALSE, recursive=TRUE)
    ## NOTE: I'm using withCallingHandlers here because that does
    ## allow options(error=recover) to behave in the expected way
    ## (i.e., the target function remains on the stack and can be
    ## inspected/browsed).
    path <- backup(target$name)
    withCallingHandlers(target_run(target, store, quiet),
                        error=function(e) {
                          restore(target$name, path)
                          stop(e)
                        })
    ## This only happens if the error is not raised above:
    target_set(target, store, NULL)
    invisible(target$name)
  } else if (target$type == "object") {
    res <- target_run(target, store, quiet)
    target_set(target, store, res)
    invisible(res)
  }
}

target_run <- function(target, store, quiet=NULL) {
  if (is.null(target$rule)) {
    return()
  } else if (inherits(target, "target_knitr")) {
    return(knitr_from_remake_target(target, store, quiet))
  }

  if (inherits(target, "target_plot")) {
    open_device(target$name, target$plot$device, target$plot$args,
                store$env$env)
    on.exit(dev.off())
  }

  envir <- target_environment(target, store)

  ## Setting quiet in a target always overrides any runtime
  ## option.
  ## TODO: quiet is not getting sanitised here.  Run via isTRUE?
  quiet <- with_default(quiet, target$quiet)

  ## TODO: Do this like testthat does:
  ##   temp <- file()
  ##   on.exit(close(temp))
  ##   result <- with_sink(temp,
  ##     withCallingHandlers(withVisible(code), 
  ##       message=mHandler))
  ## which would allow capturing of messages for debugging later,
  ## especially if an error is thrown.  However, it will not be
  ## possible to interleave the message stream and the output stream.
  if (quiet) {
    temp <- file()
    sink(temp)
    on.exit(sink())
    on.exit(close(temp), add=TRUE)
  }

  withCallingHandlers(
    eval(target$command, envir),
    message=function(e) if (quiet) invokeRestart("muffleMessage"))
}

## TODO: This will eventually take the remake object instead, but that
## requires rewriting target_run and all its tests.
target_environment <- function(target, store) {
  x <- target$depends_name[unname(target$depends_type) == "object"]
  remake_environment(list(store=store), x)
}

filter_targets <- function(targets, type=NULL,
                           include_implicit_files=FALSE,
                           include_cleanup_targets=FALSE,
                           include_chain_intermediates=FALSE) {
  ok <- rep_along(TRUE, targets)

  if (!is.null(type)) {
    ok[!(vcapply(targets, "[[", "type") %in% type)] <- FALSE
  }

  if (!include_implicit_files) {
    ok[vlapply(targets, inherits, "target_file_implicit")] <- FALSE
  }
  if (!include_cleanup_targets) {
    if ("cleanup" %in% type) {
      warning("cleanup type listed in type, but also ignored")
    }
    ok[names(targets) %in% cleanup_target_names()] <- FALSE
  }
  if (!include_chain_intermediates) {
    ok[!vlapply(targets, function(x) is.null(x$chain_parent))] <- FALSE
  }

  names(targets[ok])
}
