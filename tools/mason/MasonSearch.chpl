/*
 * Copyright 2020 Hewlett Packard Enterprise Development LP
 * Copyright 2004-2019 Cray Inc.
 * Other additional copyright holders may be indicated within.
 *
 * The entirety of this work is licensed under the Apache License,
 * Version 2.0 (the "License"); you may not use this file except
 * in compliance with the License.
 *
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

private use List;
use MasonHelp;
use MasonEnv;
use MasonUpdate;
use MasonUtils;
use TOML;

use FileSystem;
use Regexp;
use IO;

//
// TODO:
// - order results by some kind of 'best match' metric
// - allow regex searches
// - allow for exclusion of a pattern
//

//
// Temporary passthrough transforming array to list to appease the compiler.
//
proc masonSearch(args: [?d] string) {
  var listArgs: list(string);
  for x in args do listArgs.append(x);
  masonSearch(listArgs);
}

proc masonSearch(ref args: list(string)) {
  if hasOptions(args, "-h", "--help") {
    masonSearchHelp();
    exit(0);
  }

  const show = hasOptions(args, "--show");
  const debug = hasOptions(args, "--debug");
  updateRegistry("", args);

  consumeArgs(args);

  // If no query is provided, list all packages in registry
  const query = if args.size > 0 then args[args.size-1].toLower()
                else ".*";
  const pattern = compile(query, ignoreCase=true);
  var results: list(string);
  var packages: list(string);
  var versions: list(string);
  var registries: list(string);
  const numOfReg = MASON_REGISTRY.size;
  for registry in MASON_CACHED_REGISTRY {
    const searchDir = registry + "/Bricks/";

    for dir in listdir(searchDir, files=false, dirs=true) {
      const name = dir.replace("/", "");
      if pattern.search(name) {
        if isHidden(name) {
          if debug {
            writeln("[DEBUG] found hidden package: ", name);
          }
        } else {
          const ver = findLatest(searchDir + dir);
          const versionZero = new VersionInfo(0, 0, 0);
          if ver != versionZero {
            results.append(name + " (" + ver.str() + ")");
            packages.append(name);
            versions.append(ver.str());
            registries.append(registry);
          }
        }
      }
    }
  }
  var res: list(string);
  if numOfReg > 1 then res = rankResults(results, query);  
  else {
    res = rankOnScores(results, query);
    //res = rankResults(res, query);
  }
  for r in res do writeln(r);
  
  // Handle --show flag
  if show {
    if results.size == 1 {
      writeln('Displaying the latest version: ' + packages[0] + '@' + versions[0]);
      const brickPath = '/'.join(registries[0], 'Bricks', packages[0], versions[0]) + '.toml';
      showToml(brickPath);
      exit(0);
    } else if results.size == 0 {
      writeln('"' + query + '" returned no packages');
      writeln('--show requires the search to return one package');
      exit(1);
    } else if results.size > 1 {
      if query == '.*' {
        writeln('You must specify a package to show the manifest');
      } else {
        writeln('"' + query + '"  returned more than one package.');
      }
      writeln("--show requires the search to return one package.");
      exit(1);
    }
  }

  if results.size == 0 {
    exit(1);
  }
}

/* Sort based on scores from cache file */
proc rankOnScores(res: list(string), query: string) {
  use Map;
  const parse = open(MASON_HOME + '/mason-registry/cache.toml', iomode.r);
  const cacheFile = owned.create(parseToml(parse));
  var packageScores: map(string, int);
  for r in res {
    r = r.replace('(', '');
    r = r.replace(')', '');
    r = r.replace(' ', '');
    const packageName: string = r;
    const defaultScore = 5;
    var packageScore : int; 
    if cacheFile.pathExists(packageName){ 
      packageScore = cacheFile[r]!['score']!.s : int;
      packageScores.add(packageName, packageScore);
    } else packageScores.add(packageName, defaultScore);
  }
  //for r in res do writeln(r,' ', packageScores[r]);
  //writeln();
  use Sort;
  record Comparator { }
  proc Comparator.compare(a, b) {
    //writeln(a,"->",packageScores[a], ' ',b,"->",packageScores[b]);
    if packageScores[a] > packageScores[b] then return -1;
    else return 1;
  }
  var cmp : Comparator;
  var result = res.toArray();
  sort(result, comparator=cmp);
  return result;
}

/* Sort the results in a order such that results that startWith needle
   are displayed first */
proc rankResults(results: list(string), query: string): [] string {
  use Sort;
  record Comparator { }
  proc Comparator.compare(a, b) {
    if a.toLower().startsWith(query) && !b.toLower().startsWith(query) then return -1;
    else if !a.toLower().startsWith(query) && b.toLower().startsWith(query) then return 1;
    else if a.toLower().size < b.toLower().size then return -1;
    else return 1;
  }
  var cmp : Comparator;
  var res = results.toArray();
  if query == ".*" then sort(res);
  else sort(res, comparator=cmp);
  return res;
}

proc isHidden(name : string) : bool {
  return name.startsWith("_");
}

/* Search TOML files within a package directory to find the latest package
   version number that is supported with current Chapel version */
proc findLatest(packageDir: string): VersionInfo {
  use Path;

  var ret = new VersionInfo(0, 0, 0);
  const suffix = ".toml";
  const packageName = basename(packageDir);
  for manifest in listdir(packageDir, files=true, dirs=false) {
    // Check that it is a valid TOML file
    if !manifest.endsWith(suffix) {
      var warningStr = "File without '.toml' extension encountered - skipping ";
      warningStr += packageName + " " + manifest;
      stderr.writeln(warningStr);
      continue;
    }

    // Skip packages that are out of version bounds
    const chplVersion = getChapelVersionInfo();

    const manifestReader = openreader(packageDir + '/' + manifest);
    const manifestToml = owned.create(parseToml(manifestReader));
    const brick = manifestToml['brick'];
    var (low, high) = parseChplVersion(brick);
    if chplVersion < low || chplVersion > high then continue;

    // Check that Chapel version is supported
    const end = manifest.size - suffix.size;
    const ver = new VersionInfo(manifest[0..<end]);
    if ver > ret then ret = ver;
  }
  return ret;
}

proc consumeArgs(ref args : list(string)) {
  args.pop(0);
  const sub = args[0];
  assert(sub == "search");
  args.pop(0);

  const options = {"--no-update", "--debug", "--show"};

  while args.size > 0 && options.contains(args[0]) {
    args.pop(0);
  }
}


/* Print a TOML file. Expects full path. */
proc showToml(tomlFile : string) {
  const openFile = openreader(tomlFile);
  const toml = owned.create(parseToml(openFile));
  writeln(toml);
  openFile.close();
}
