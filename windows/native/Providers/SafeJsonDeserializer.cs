using System;
using System.Collections.Generic;
using System.Globalization;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace AITaskMonitor.ExternalProviders
{
    // Compatibility prototype for the bounded, sanitized provider event parser.
    internal sealed class SafeJsonDeserializer
    {
        private static readonly Regex LegacyDate = new Regex(
            "^\"\\\\/Date\\((?<ticks>-?[0-9]+)(?:[A-Za-z]|[+-][0-9]{4})?\\)\\\\/\"$",
            RegexOptions.CultureInvariant);
        public int MaxJsonLength { get; set; }
        public int RecursionLimit { get; set; }

        public object DeserializeObject(string json)
        {
            if (json == null || json.Length > MaxJsonLength)
                throw new ArgumentException("Invalid provider frame.");

            try
            {
                // Normalise malformed escaped UTF-16 before parsing so that object
                // member names and string values receive the same replacement.
                using (var document = JsonDocument.Parse(ReplaceIsolatedSurrogates(json),
                           new JsonDocumentOptions { MaxDepth = RecursionLimit }))
                    return ConvertElement(document.RootElement, 1);
            }
            catch (JsonException ex)
            {
                throw new ArgumentException("Invalid provider frame.", ex);
            }
        }

        private object ConvertElement(JsonElement element, int depth)
        {
            // The old parser counts scalar values as a level too, including values
            // that are later overwritten by a duplicate property.
            if (depth > RecursionLimit)
                throw new ArgumentException("Provider frame is too deeply nested.");
            switch (element.ValueKind)
            {
                case JsonValueKind.Object:
                    var map = new Dictionary<string, object>(StringComparer.Ordinal);
                    foreach (JsonProperty property in element.EnumerateObject())
                        map[property.Name] = ConvertElement(property.Value, depth + 1);
                    return map;
                case JsonValueKind.Array:
                    var items = new List<object>();
                    foreach (JsonElement item in element.EnumerateArray())
                        items.Add(ConvertElement(item, depth + 1));
                    return items.ToArray();
                case JsonValueKind.String:
                    return ConvertString(element);
                case JsonValueKind.Number:
                    string raw = element.GetRawText();
                    if (raw.IndexOfAny(new[] { '.', 'e', 'E' }) < 0)
                    {
                        if (element.TryGetInt32(out int integer)) return integer;
                        if (element.TryGetInt64(out long longInteger)) return longInteger;
                    }
                    if (element.TryGetDecimal(out decimal decimalNumber)) return decimalNumber;
                    if (element.TryGetDouble(out double doubleNumber) &&
                        !Double.IsInfinity(doubleNumber) && !Double.IsNaN(doubleNumber)) return doubleNumber;
                    throw new ArgumentException("Invalid provider number.");
                case JsonValueKind.True:
                    return true;
                case JsonValueKind.False:
                    return false;
                case JsonValueKind.Null:
                    return null;
                default:
                    throw new ArgumentException("Invalid provider value.");
            }
        }

        private static object ConvertString(JsonElement element)
        {
            string raw = element.GetRawText();
            Match match = LegacyDate.Match(raw);
            if (match.Success && Int64.TryParse(match.Groups["ticks"].Value,
                    NumberStyles.Integer, CultureInfo.InvariantCulture, out long milliseconds))
            {
                // The Framework parser uses unchecked Int64 arithmetic here.
                long ticks = unchecked(milliseconds * 10000L + 621355968000000000L);
                return new DateTime(ticks, DateTimeKind.Utc);
            }
            try
            {
                return element.GetString();
            }
            catch (InvalidOperationException)
            {
                // Preserve the Framework parser's replacement of isolated UTF-16
                // surrogates while keeping valid pairs and escaped backslashes intact.
                return JsonSerializer.Deserialize<string>(ReplaceIsolatedSurrogates(raw));
            }
        }

        private static string ReplaceIsolatedSurrogates(string raw)
        {
            var result = new StringBuilder(raw.Length);
            int index = 0;
            while (index < raw.Length)
            {
                if (raw[index] != '\\' || index + 1 >= raw.Length)
                {
                    result.Append(raw[index++]);
                    continue;
                }
                if (raw[index + 1] != 'u')
                {
                    result.Append(raw, index, 2);
                    index += 2;
                    continue;
                }
                if (!TryEscapedCodeUnit(raw, index, out char unit))
                    throw new ArgumentException("Invalid provider string.");
                if (Char.IsHighSurrogate(unit))
                {
                    if (TryEscapedCodeUnit(raw, index + 6, out char next) && Char.IsLowSurrogate(next))
                    {
                        result.Append(raw, index, 12);
                        index += 12;
                        continue;
                    }
                    result.Append("\\uFFFD");
                }
                else if (Char.IsLowSurrogate(unit)) result.Append("\\uFFFD");
                else result.Append(raw, index, 6);
                index += 6;
            }
            return result.ToString();
        }

        private static bool TryEscapedCodeUnit(string raw, int index, out char unit)
        {
            unit = '\0';
            if (index + 6 > raw.Length || raw[index] != '\\' || raw[index + 1] != 'u') return false;
            if (!UInt16.TryParse(raw.Substring(index + 2, 4), NumberStyles.AllowHexSpecifier,
                    CultureInfo.InvariantCulture, out ushort value)) return false;
            unit = (char)value;
            return true;
        }
    }
}
