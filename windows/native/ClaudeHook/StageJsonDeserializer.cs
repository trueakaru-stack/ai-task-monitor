#nullable disable
using System;
using System.Collections.Generic;
using System.Text.Json;

// The shared Framework phase classifier uses JavaScriptSerializer. This
// bounded adapter supplies the dictionary/array/scalar types it consumes on
// .NET 10. The classifier performs its own strict JSON and duplicate checks.
namespace System.Web.Script.Serialization
{
    internal sealed class JavaScriptSerializer
    {
        public int MaxJsonLength { get; set; }
        public int RecursionLimit { get; set; }

        public object DeserializeObject(string json)
        {
            if (json == null || json.Length > MaxJsonLength) throw new ArgumentException("Invalid hook input.");
            try
            {
                using JsonDocument document = JsonDocument.Parse(json, new JsonDocumentOptions { MaxDepth = RecursionLimit });
                return ConvertValue(document.RootElement);
            }
            catch (JsonException error) { throw new ArgumentException("Invalid hook input.", error); }
        }

        private static object ConvertValue(JsonElement element)
        {
            switch (element.ValueKind)
            {
                case JsonValueKind.Object:
                    var dictionary = new Dictionary<string, object>(StringComparer.Ordinal);
                    foreach (JsonProperty property in element.EnumerateObject()) dictionary.Add(property.Name, ConvertValue(property.Value));
                    return dictionary;
                case JsonValueKind.Array:
                    var array = new List<object>();
                    foreach (JsonElement item in element.EnumerateArray()) array.Add(ConvertValue(item));
                    return array.ToArray();
                case JsonValueKind.String:
                    string text = element.GetString();
                    // Framework JavaScriptSerializer converts some /Date(...)/
                    // strings to DateTime. Conservatively avoid treating any such
                    // value as a proven string, even when its spelling is unusual.
                    if (text != null && text.StartsWith("/Date(", StringComparison.Ordinal) &&
                        text.EndsWith(")/", StringComparison.Ordinal)) return new object();
                    return text;
                case JsonValueKind.True: return true;
                case JsonValueKind.False: return false;
                case JsonValueKind.Null: return null;
                case JsonValueKind.Number:
                    if (element.TryGetInt32(out int int32)) return int32;
                    if (element.TryGetInt64(out long int64)) return int64;
                    if (element.TryGetDecimal(out decimal number)) return number;
                    if (element.TryGetDouble(out double floating) && double.IsFinite(floating)) return floating;
                    throw new ArgumentException("Unsupported hook number.");
                default: throw new ArgumentException("Unsupported hook value.");
            }
        }
    }
}
