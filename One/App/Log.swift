import os

/// アプリの中で起きたことを記録する。
///
/// メニューバー常駐アプリは画面が無いので、`print` を書いても普段は誰にも見えない。
/// `Logger` に書いておくと、アプリを Xcode から離して起動していても、後から
/// ターミナルで読み返せる。
///
/// ```sh
/// log show --last 5m --predicate 'subsystem == "com.finalize.one"' --style compact
/// log stream --predicate 'subsystem == "com.finalize.one"'   # 流しながら見る
/// ```
///
/// 使い分け:
///
/// - `notice` … ディスクに残る。起動・許可・監視開始のような、後から追いたい節目だけ。
/// - `debug`  … 残らない。打鍵ごとに出るような細かいものはこちら。
/// - `error`  … 残る。想定外のことが起きたとき。
///
/// 打鍵のたびに `notice` を書くと、いつ何のキーを押したかがディスクに溜まり続ける。
/// 常駐アプリでそれをやるのは行儀が悪いので、細かいものは `debug` に落としてある。
/// `debug` は既定で無効なので、見たいときは明示的に有効にする:
///
/// ```sh
/// log stream --debug --predicate 'subsystem == "com.finalize.one"'
/// ```
let log = Logger(subsystem: "com.finalize.one", category: "one")
