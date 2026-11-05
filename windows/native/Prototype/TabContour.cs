using System.Windows;
using System.Windows.Media;

namespace AITaskMonitor.Prototype;

// The points reproduce the exported SwiftUI continuous corners for the
// currently used 42/r14 and 34/r10 tab heights. Other sizes keep the previous
// WPF contour; the exported Mac data does not establish their geometry.
internal static class TabContour
{
    private readonly record struct Metrics(double XLength, double YLength,
        double XControl1, double XControl2, double YControl1, double YControl2,
        double Near, double Far, double DiagonalNear, double DiagonalFar);

    private static readonly Metrics Track = new(
        21.401309251785278, 21, 15.238860130310059, 12.157698154449463,
        15.14132285118103, 12.120952486991882, 1.0487596094608307,
        8.84091579914093, 2.3668400943279266, 5.2195361852645874);
    private static readonly Metrics Segment = new(
        15.286649465560913, 15.286649465560913, 10.884900093078613,
        8.684070110321045, 10.884900093078613, 8.684070110321045,
        0.7491140067577362, 6.314939856529236, 1.6906000673770905,
        3.728240132331848);

    public static Geometry Create(double width, double height, double radius)
    {
        Metrics? metric = height == 42 && radius == 14 ? Track :
            height == 34 && radius == 10 ? Segment : null;
        if (metric is not { } m || !double.IsFinite(width) || width < 2 * m.XLength)
            return Squircle.Create(width, height, radius, 0, radius == 14 ? 0.56 : 0.60);

        double xl = m.XLength, yl = m.YLength, xc1 = m.XControl1, xc2 = m.XControl2;
        double yc1 = m.YControl1, yc2 = m.YControl2, n = m.Near, f = m.Far;
        double dn = m.DiagonalNear, df = m.DiagonalFar;
        var figure = new PathFigure { StartPoint = new Point(width, height / 2), IsClosed = true };
        void Line(double x, double y) => figure.Segments.Add(new LineSegment(new Point(x, y), true));
        void Cubic(double x1, double y1, double x2, double y2, double x3, double y3) =>
            figure.Segments.Add(new BezierSegment(new Point(x1, y1), new Point(x2, y2), new Point(x3, y3), true));

        Line(width, height - yl);
        Cubic(width, height - yc1, width, height - yc2, width - n, height - f);
        Cubic(width - dn, height - df, width - df, height - dn, width - f, height - n);
        Cubic(width - xc2, height, width - xc1, height, width - xl, height);
        Line(xl, height);
        Cubic(xc1, height, xc2, height, f, height - n);
        Cubic(df, height - dn, dn, height - df, n, height - f);
        Cubic(0, height - yc2, 0, height - yc1, 0, height - yl);
        Line(0, yl);
        Cubic(0, yc1, 0, yc2, n, f);
        Cubic(dn, df, df, dn, f, n);
        Cubic(xc2, 0, xc1, 0, xl, 0);
        Line(width - xl, 0);
        Cubic(width - xc1, 0, width - xc2, 0, width - f, n);
        Cubic(width - df, dn, width - dn, df, width - n, f);
        Cubic(width, yc2, width, yc1, width, yl);
        return new PathGeometry(new[] { figure });
    }
}
