// Smoke test for the cppdev image.
//
// Part 1 uses C++26 features that both GCC 16 and Clang 23 implement. If any of
// them regress, this file stops compiling or the program exits non-zero.
// Part 2 exercises newer C++26 features that only some toolchains ship so far;
// each one is compiled in only when the toolchain advertises it.

#include <array>
#include <charconv>
#include <cstddef>
#include <cstdint>
#include <format>
#include <limits>
#include <memory>
#include <new>
#include <numeric>
#include <optional>
#include <print>
#include <span>
#include <stdexcept>
#include <string>
#include <string_view>
#include <tuple>
#include <type_traits>
#include <utility>
#include <vector>
#include <version>

#if __cplusplus <= 202302L
#  error "this example must be compiled as C++26 (-std=c++26)"
#endif

#if __has_include(<inplace_vector>)
#  include <inplace_vector>
#endif
#if __has_include(<ranges>)
#  include <ranges>
#endif
#if __has_include(<functional>)
#  include <functional>
#endif
#if __has_include(<text_encoding>)
#  include <text_encoding>
#endif
#if defined(__cpp_impl_reflection) && __has_include(<meta>)
#  include <meta>
#endif

namespace {

int failures = 0;

void check(std::string_view what, bool ok) {
  std::println("  [{}] {}", ok ? " ok " : "FAIL", what);
  failures += ok ? 0 : 1;
}

[[maybe_unused]] void unavailable(std::string_view what) { std::println("  [ -- ] {}", what); }

// ---------------------------------------------------------------------------
// Part 1: C++26 features available in both GCC 16 and Clang 23
// ---------------------------------------------------------------------------

// Pack indexing (P2662)
template <typename... Ts>
using first_t = Ts...[0];

template <std::size_t I, typename... Ts>
constexpr auto nth(Ts... args) {
  return args...[I];
}

static_assert(std::is_same_v<first_t<int, double, char>, int>);
static_assert(nth<2>(1, 2.5, 'c') == 'c');

// = delete("reason") (P2573)
constexpr int halve(int n) { return n / 2; }
double halve(double) = delete("halve() is integer-only; round explicitly first");

template <typename T>
concept halvable = requires(T v) { halve(v); };
static_assert(halvable<int> && !halvable<double>);

// User-generated static_assert messages (P2741)
constexpr std::string_view int_width_message() { return "this example assumes a 32-bit int"; }
static_assert(sizeof(int) == 4, int_width_message());

// #embed (P1967), with the standard suffix() parameter appending the terminator.
// Clang 23 still reports #embed as an extension in C++ mode under -Wpedantic.
#if defined(__clang__)
#  pragma clang diagnostic push
#  pragma clang diagnostic ignored "-Wc23-extensions"
#endif
constexpr char banner[] = {
#embed "banner.txt" suffix(, '\0')
};
#if defined(__clang__)
#  pragma clang diagnostic pop
#endif
static_assert(std::string_view{banner}.starts_with("cppdev"));

// Structured binding declaration as a condition (P0963), tested through
// from_chars_result::operator bool (P2497). The unused binding is a placeholder (P2169).
constexpr std::optional<int> parse_int(std::string_view text) {
  int value = 0;
  if (auto [end, _] = std::from_chars(text.data(), text.data() + text.size(), value)) {
    return end == text.data() + text.size() ? std::optional{value} : std::nullopt;
  }
  return std::nullopt;
}
static_assert(parse_int("2026") == 2026);
static_assert(!parse_int("26x") && !parse_int("nope"));

// constexpr placement new (P2747)
constexpr int placement_new_at_compile_time() {
  std::allocator<int> alloc;
  int* storage = alloc.allocate(1);
  int* value = ::new (static_cast<void*>(storage)) int(26);
  const int result = *value;
  std::destroy_at(value);
  alloc.deallocate(storage, 1);
  return result;
}
static_assert(placement_new_at_compile_time() == 26);

// Variadic friends (P2893): a passkey that only the listed types can create.
template <typename... Allowed>
class Passkey {
  friend Allowed...;
  constexpr Passkey() = default;
};

class Registry;

class Widget {
 public:
  explicit Widget(Passkey<Registry> /*key*/, int id) : id_(id) {}
  [[nodiscard]] int id() const { return id_; }

 private:
  int id_;
};

class Registry {
 public:
  Widget& make() { return widgets_.emplace_back(Passkey<Registry>{}, static_cast<int>(widgets_.size())); }
  [[nodiscard]] std::size_t size() const { return widgets_.size(); }

 private:
  std::vector<Widget> widgets_;
};
static_assert(!std::is_default_constructible_v<Passkey<Registry>>);

// Saturation arithmetic (P0543; the final C++26 names are saturating_*, not add_sat etc.)
static_assert(std::saturating_add<std::uint8_t>(200, 100) == 255);
static_assert(std::saturating_sub<std::uint8_t>(10, 20) == 0);
static_assert(std::saturating_mul<std::int16_t>(300, 300) == std::numeric_limits<std::int16_t>::max());
static_assert(std::saturating_cast<std::int8_t>(1000) == 127);

void portable_features() {
  std::println("C++26 features shared by GCC 16 and Clang 23:");

  check("pack indexing: Ts...[0] and args...[I]", nth<1>(1, 2.5, 'c') == 2.5);
  check("= delete(\"reason\") rejects halve(double)", halve(9) == 4);
  check("#embed banner.txt", std::string_view{banner}.ends_with("#embed\n"));
  check("structured binding as if-condition", parse_int("42") == 42 && !parse_int("4 2"));
  check("constexpr placement new", placement_new_at_compile_time() == 26);

  // Placeholder variables (P2169): several `_` in one scope; attributes on
  // structured bindings (P0609).
  const auto [_, _, third [[maybe_unused]]] = std::tuple{"ignored", 1.0, 3};
  check("placeholder variables and binding attributes", third == 3);

  Registry registry;
  registry.make();
  check("variadic friend passkey", registry.make().id() == 1 && registry.size() == 2);

  check("saturation arithmetic", std::saturating_add(std::numeric_limits<int>::max(), 1) ==
                                     std::numeric_limits<int>::max());

  // std::span::at (P2821) throws instead of invoking UB.
  std::array numbers{1, 2, 3};
  const std::span view{numbers};
  bool threw = false;
  try {
    static_cast<void>(view.at(numbers.size()));
  } catch (const std::out_of_range&) {
    threw = true;
  }
  check("std::span::at bounds check", threw && view.at(2) == 3);

  // std::dynamic_format (P2918, renamed from runtime_format): format strings only known at run time.
  const std::string pattern = "{} + {} = {}";
  check("std::dynamic_format", std::format(std::dynamic_format(pattern), 20, 6, 26) == "20 + 6 = 26");
}

// ---------------------------------------------------------------------------
// Part 2: newer C++26 features, compiled in only where available
// ---------------------------------------------------------------------------

#if __cpp_structured_bindings >= 202411L
template <typename Tuple>
constexpr auto sum_all(const Tuple& tuple) {
  const auto& [... elements] = tuple;  // P1061: structured binding packs
  return (elements + ...);
}
#endif

#ifdef __cpp_expansion_statements
template <typename Tuple>
constexpr std::size_t total_size(const Tuple& tuple) {
  std::size_t total = 0;
  template for (const auto& element : tuple) {  // P1306: expansion statements
    total += sizeof(element);
  }
  return total;
}
#endif

#ifdef __cpp_constexpr_exceptions
constexpr bool throws_at_compile_time() {
  try {
    throw std::runtime_error("thrown during constant evaluation");  // P3068
  } catch (const std::exception&) {
    return true;
  }
}
#endif

#ifdef __cpp_contracts
int integer_sqrt(const int n)  // parameters named in a postcondition must be const
  pre(n >= 0)
  post(r : r * r <= n && (r + 1) * (r + 1) > n)  // P2900: contracts
{
  int root = 0;
  while ((root + 1) * (root + 1) <= n) {
    ++root;
  }
  contract_assert(root >= 0);
  return root;
}
#endif

#if defined(__cpp_impl_reflection) && defined(__cpp_expansion_statements)
enum class Color { red, green, blue };

template <typename E>
  requires std::is_enum_v<E>
constexpr std::string_view enum_name(E value) {
  template for (constexpr auto e : std::define_static_array(std::meta::enumerators_of(^^E))) {
    if (value == [:e:]) {
      return std::meta::identifier_of(e);
    }
  }
  return "<unknown>";
}
#endif

void newer_features() {
  std::println("\nNewer C++26 features (support varies by toolchain):");

#if __cpp_structured_bindings >= 202411L
  check("structured binding packs (P1061)", sum_all(std::tuple{1, 2, 3, 20}) == 26);
#else
  unavailable("structured binding packs (P1061)");
#endif

#ifdef __cpp_expansion_statements
  check("expansion statements: template for (P1306)",
        total_size(std::tuple{std::int8_t{}, std::int32_t{}}) == 5);
#else
  unavailable("expansion statements: template for (P1306)");
#endif

#if defined(__cpp_impl_reflection) && defined(__cpp_expansion_statements)
  check("static reflection: enum_name(Color::green) (P2996)", enum_name(Color::green) == "green");
#else
  unavailable("static reflection (P2996)");
#endif

#ifdef __cpp_contracts
  check("contracts: pre/post/contract_assert (P2900)", integer_sqrt(26) == 5);
#else
  unavailable("contracts (P2900)");
#endif

#ifdef __cpp_constexpr_exceptions
  static_assert(throws_at_compile_time());
  check("exceptions during constant evaluation (P3068)", true);
#else
  unavailable("exceptions during constant evaluation (P3068)");
#endif

#ifdef __cpp_lib_inplace_vector
  std::inplace_vector<int, 2> small;
  small.push_back(1);
  small.push_back(2);
  check("std::inplace_vector (P0843)", !small.try_push_back(3) && small.size() == 2);
#else
  unavailable("std::inplace_vector (P0843)");
#endif

#ifdef __cpp_lib_ranges_concat
  const std::vector<int> head{1, 2};
  const std::array<int, 2> tail{3, 20};
  int concat_total = 0;
  for (const int n : std::views::concat(head, tail)) {
    concat_total += n;
  }
  check("std::views::concat (P2542)", concat_total == 26);
#else
  unavailable("std::views::concat (P2542)");
#endif

#ifdef __cpp_lib_function_ref
  const auto twice = [](int n) { return 2 * n; };
  const std::function_ref<int(int)> callback = twice;
  check("std::function_ref (P0792)", callback(13) == 26);
#else
  unavailable("std::function_ref (P0792)");
#endif

#ifdef __cpp_lib_text_encoding
  check("std::text_encoding::literal() (P1885)", !std::string_view{std::text_encoding::literal().name()}.empty());
#else
  unavailable("std::text_encoding (P1885)");
#endif
}

void print_toolchain() {
#if defined(__clang__)
  std::println("Compiler: Clang {}.{}.{}", __clang_major__, __clang_minor__, __clang_patchlevel__);
#elif defined(__GNUC__)
  std::println("Compiler: GCC {}.{}.{}", __GNUC__, __GNUC_MINOR__, __GNUC_PATCHLEVEL__);
#endif
#if defined(_LIBCPP_VERSION)
  std::println("Standard library: libc++ {}", _LIBCPP_VERSION);
#elif defined(__GLIBCXX__)
  std::println("Standard library: libstdc++ {}", __GLIBCXX__);
#endif
  std::println("__cplusplus: {}\n", __cplusplus);
}

}  // namespace

int main() {
  std::print("{}", banner);
  print_toolchain();
  portable_features();
  newer_features();

  if (failures != 0) {
    std::println("\n{} check(s) failed", failures);
    return 1;
  }
  std::println("\nAll checks passed.");
  return 0;
}
